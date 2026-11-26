import AVFoundation
import CoreAudio
import Foundation
import SpeakCore
import os.log

/// Captures macOS system audio (and optionally mixes the microphone) via a
/// CoreAudio Process Tap (macOS 14.2+).
///
/// Writes a 16-bit 48 kHz mono WAV file so History playback, retry, batch cloud
/// models, and local models work identically to microphone recordings, while
/// also forwarding 48 kHz mono Float32 buffers to `SystemAudioLiveFeed` for
/// live streaming transcription.
@available(macOS 14.2, *)
final class SystemAudioCaptureController: @unchecked Sendable {
    private struct StoppedCapture {
        let url: URL?
        let id: UUID?
        let startedAt: Date?
        let writeError: Error?
    }

    static let canonicalSampleRate: Double = 48_000

    let logger = Logger(subsystem: "com.github.speakapp", category: "SystemAudioCapture")
    let callbackQueue = DispatchQueue(label: "com.justspeaktoit.systemAudio.io", qos: .userInteractive)
    let writerQueue = DispatchQueue(label: "com.justspeaktoit.systemAudio.writer", qos: .userInitiated)
    private let meterLock = NSLock()

    var canonicalFormat: AVAudioFormat?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapConverter: AVAudioConverter?
    var micConverter: AVAudioConverter?
    var micEngine: AVAudioEngine?
    private var activeInputSession: AudioInputDeviceManager.SessionContext?
    private var audioDeviceManager: AudioInputDeviceManager?

    var mixer: SystemAudioMixer?
    var audioFile: AVAudioFile?
    var liveFeed: SystemAudioLiveFeed?
    var writeError: Error?
    private var recordingID: UUID?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var isCapturing = false

    private var latestLevel: Float = 0
    private var latestPeakDecibels: Float = -160

    init() {
        self.canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.canonicalSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    func currentMeterReading() -> (level: Float, peakDecibels: Float)? {
        meterLock.lock()
        defer { meterLock.unlock() }
        guard isCapturing else { return nil }
        return (latestLevel, latestPeakDecibels)
    }

    func start(
        source: AudioCaptureSource,
        in directory: URL,
        liveFeed: SystemAudioLiveFeed,
        audioDeviceManager: AudioInputDeviceManager,
        permissionsManager: PermissionsManager
    ) async throws -> RecordingStart {
        guard let canonicalFormat else {
            throw SystemAudioCaptureError.invalidTapFormat
        }
        if source.includesMicrophone {
            let status = await permissionsManager.ensureGranted(.microphone)
            guard status.isGranted else {
                throw AudioFileManagerError.microphonePermissionMissing
            }
            self.activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
            self.audioDeviceManager = audioDeviceManager
        }

        let id = UUID()
        let fileURL = directory.appendingPathComponent("Recording-\(id.uuidString).wav")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let file = try SystemAudioTapHardware.makeOutputFile(at: fileURL, sampleRate: Self.canonicalSampleRate)
            let mixer = SystemAudioMixer(source: source, sampleRate: Int(Self.canonicalSampleRate))

            writerQueue.sync {
                self.audioFile = file
                self.mixer = mixer
                self.liveFeed = liveFeed
                self.writeError = nil
                self.recordingID = id
                self.recordingURL = fileURL
                self.startedAt = Date()
            }

            try startCoreAudioTap(mixer: mixer, canonicalFormat: canonicalFormat)
            if source == .both {
                try await startMicrophoneMix(canonicalFormat: canonicalFormat)
            }

            meterLock.lock()
            self.isCapturing = true
            self.latestLevel = 0
            self.latestPeakDecibels = -160
            meterLock.unlock()

            var start = RecordingStart(url: fileURL, usedWarmRecorder: false)
            start.liveUptime = ProcessInfo.processInfo.systemUptime
            return start
        } catch {
            await teardown(deleteFile: true)
            throw error
        }
    }

    func stop() async throws -> RecordingSummary {
        stopCaptureHardware()

        let stopped = writerQueue.sync { () -> StoppedCapture in
            if let remaining = self.mixer?.flush(), !remaining.isEmpty {
                self.writeAndForwardLocked(remaining)
            }
            self.liveFeed?.close()
            self.liveFeed = nil
            self.audioFile = nil
            self.mixer = nil
            let result = StoppedCapture(
                url: self.recordingURL, id: self.recordingID, startedAt: self.startedAt, writeError: self.writeError
            )
            self.writeError = nil
            self.recordingURL = nil
            self.recordingID = nil
            self.startedAt = nil
            return result
        }

        await releaseInputSessionIfNeeded()

        if let writeError = stopped.writeError {
            throw writeError
        }
        guard let url = stopped.url, let id = stopped.id, let start = stopped.startedAt else {
            throw AudioFileManagerError.noActiveRecording
        }
        return AudioRecorderFactory.summary(
            of: url,
            id: id,
            startedAt: start,
            measuredDuration: max(0, Date().timeIntervalSince(start))
        )
    }

    func cancel(deleteFile: Bool) async {
        await teardown(deleteFile: deleteFile)
    }

    // MARK: - CoreAudio Process Tap

    private func startCoreAudioTap(mixer: SystemAudioMixer, canonicalFormat: AVAudioFormat) throws {
        _ = mixer
        let created = try SystemAudioTapHardware.createGlobalTapExcludingSelf()
        self.tapID = created.tapID
        self.aggregateDeviceID = created.aggregateDeviceID

        guard let converter = AVAudioConverter(from: created.tapFormat, to: canonicalFormat) else {
            throw SystemAudioCaptureError.invalidTapFormat
        }
        self.tapConverter = converter

        var createdIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProcID,
            created.aggregateDeviceID,
            callbackQueue
        ) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handleTapInput(
                inInputData,
                tapFormat: created.tapFormat,
                canonicalFormat: canonicalFormat,
                converter: converter
            )
        }
        guard ioStatus == noErr, let createdIOProcID else {
            throw SystemAudioCaptureError.ioProcFailed(ioStatus)
        }
        self.ioProcID = createdIOProcID

        let startStatus = AudioDeviceStart(created.aggregateDeviceID, createdIOProcID)
        guard startStatus == noErr else {
            throw SystemAudioCaptureError.ioProcFailed(startStatus)
        }
    }

    func recordMeter(level: Float, peakDecibels: Float) {
        meterLock.lock()
        latestLevel = level
        latestPeakDecibels = peakDecibels
        meterLock.unlock()
    }

    // MARK: - Teardown

    struct HardwareHandles {
        let micEngine: AVAudioEngine?
        let ioProc: AudioDeviceIOProcID?
        let aggregateDevice: AudioObjectID
        let tap: AudioObjectID
    }

    func resetMeterStopped() {
        meterLock.lock()
        isCapturing = false
        latestLevel = 0
        latestPeakDecibels = -160
        meterLock.unlock()
    }

    func clearHardwareHandles() -> HardwareHandles {
        let handles = HardwareHandles(
            micEngine: micEngine,
            ioProc: ioProcID,
            aggregateDevice: aggregateDeviceID,
            tap: tapID
        )
        micEngine = nil
        micConverter = nil
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapConverter = nil
        return handles
    }

    func teardown(deleteFile: Bool) async {
        stopCaptureHardware()
        let urlToDelete: URL? = writerQueue.sync {
            self.liveFeed?.close()
            self.liveFeed = nil
            self.audioFile = nil
            self.mixer = nil
            let url = self.recordingURL
            self.recordingURL = nil
            self.recordingID = nil
            self.startedAt = nil
            return deleteFile ? url : nil
        }
        if let urlToDelete {
            try? FileManager.default.removeItem(at: urlToDelete)
        }
        await releaseInputSessionIfNeeded()
    }

    private func releaseInputSessionIfNeeded() async {
        guard let session = activeInputSession, let manager = audioDeviceManager else { return }
        activeInputSession = nil
        audioDeviceManager = nil
        await manager.endUsingPreferredInput(session: session)
    }
}
