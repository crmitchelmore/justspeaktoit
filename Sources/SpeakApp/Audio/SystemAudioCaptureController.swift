import AVFoundation
import CoreAudio
import Foundation
import SpeakCore
import os.log

enum SystemAudioCaptureError: LocalizedError, Equatable {
    case unsupportedOS
    case processTapFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case invalidTapFormat
    case fileCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "System audio capture requires macOS 14.2 or later."
        case .processTapFailed(let status):
            "Could not create a system audio tap (OSStatus \(status)). "
                + "Allow Just Speak to It in System Settings → Privacy & Security → System Audio Recording Only."
        case .aggregateDeviceFailed(let status):
            "Could not create the system audio capture device (OSStatus \(status))."
        case .ioProcFailed(let status):
            "Could not start system audio capture (OSStatus \(status))."
        case .invalidTapFormat:
            "The system audio tap reported an unusable audio format."
        case .fileCreationFailed:
            "Could not create the system audio recording file."
        }
    }
}

/// Captures macOS system audio (and optionally mixes the microphone) via a
/// CoreAudio Process Tap (macOS 14.2+).
///
/// Writes a 16-bit 48 kHz mono WAV file so History playback, retry, batch cloud
/// models, and local models work identically to microphone recordings, while
/// also forwarding 48 kHz mono Float32 buffers to `SystemAudioLiveFeed` for
/// live streaming transcription.
@available(macOS 14.2, *)
final class SystemAudioCaptureController: @unchecked Sendable {
    static let canonicalSampleRate: Double = 48_000

    private let logger = Logger(subsystem: "com.github.speakapp", category: "SystemAudioCapture")
    private let callbackQueue = DispatchQueue(label: "com.justspeaktoit.systemAudio.io", qos: .userInteractive)
    private let writerQueue = DispatchQueue(label: "com.justspeaktoit.systemAudio.writer", qos: .userInitiated)
    private let meterLock = NSLock()

    private var canonicalFormat: AVAudioFormat?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var micEngine: AVAudioEngine?
    private var activeInputSession: AudioInputDeviceManager.SessionContext?
    private var audioDeviceManager: AudioInputDeviceManager?

    private var mixer: SystemAudioMixer?
    private var audioFile: AVAudioFile?
    private var liveFeed: SystemAudioLiveFeed?
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
                throw AudioFileManagerError.microphonePermissionDenied
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
                self.recordingID = id
                self.recordingURL = fileURL
                self.startedAt = Date()
            }

            try startCoreAudioTap(mixer: mixer, canonicalFormat: canonicalFormat)
            if source == .both {
                try await startMicrophoneMix(mixer: mixer, canonicalFormat: canonicalFormat)
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

        let (summaryURL, summaryID, summaryStart) = writerQueue.sync { () -> (URL?, UUID?, Date?) in
            if let remaining = self.mixer?.flush(), !remaining.isEmpty {
                self.writeAndForwardLocked(remaining)
            }
            self.liveFeed?.close()
            self.liveFeed = nil
            self.audioFile = nil
            self.mixer = nil
            let result = (self.recordingURL, self.recordingID, self.startedAt)
            self.recordingURL = nil
            self.recordingID = nil
            self.startedAt = nil
            return result
        }

        await releaseInputSessionIfNeeded()

        guard let url = summaryURL, let id = summaryID, let start = summaryStart else {
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
                converter: converter,
                mixer: mixer
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

    private func handleTapInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        tapFormat: AVAudioFormat,
        canonicalFormat: AVAudioFormat,
        converter: AVAudioConverter,
        mixer: SystemAudioMixer
    ) {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = bufferList.first, firstBuffer.mDataByteSize > 0 else { return }
        let bytesPerFrame = Int(tapFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount
        let destination = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: pcmBuffer.audioBufferList)
        )
        let copyCount = min(bufferList.count, destination.count)
        for index in 0..<copyCount {
            guard let src = bufferList[index].mData, let dst = destination[index].mData else { continue }
            let byteCount = min(Int(bufferList[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(dst, src, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }

        let samples = convertToCanonicalSamples(pcmBuffer, canonicalFormat: canonicalFormat, using: converter)
        guard !samples.isEmpty else { return }
        let mixed = mixer.pushSystem(samples)
        if !mixed.isEmpty {
            enqueueMixed(mixed)
        }
    }

    // MARK: - Optional Microphone Mixing (.both)

    private func startMicrophoneMix(mixer: SystemAudioMixer, canonicalFormat: AVAudioFormat) async throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard audioInputFormatIsUsable(inputFormat),
              let converter = AVAudioConverter(from: inputFormat, to: canonicalFormat) else {
            throw TranscriptionManagerError.noUsableAudioInput
        }
        self.micConverter = converter
        self.micEngine = engine
        try inputNode.installTapSafely(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convertToCanonicalSamples(
                buffer,
                canonicalFormat: canonicalFormat,
                using: converter
            )
            guard !samples.isEmpty else { return }
            let mixed = mixer.pushMicrophone(samples)
            if !mixed.isEmpty {
                self.enqueueMixed(mixed)
            }
        }
        try await startAudioEngineAfterInputDeviceSettles(engine)
    }

    // MARK: - Conversion, Writing & Metering

    private func convertToCanonicalSamples(
        _ buffer: AVAudioPCMBuffer,
        canonicalFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if buffer.format == canonicalFormat, let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        let ratio = canonicalFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 16))
        guard let output = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            return []
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func enqueueMixed(_ samples: [Float]) {
        writerQueue.async { [weak self] in
            self?.writeAndForwardLocked(samples)
        }
    }

    private func writeAndForwardLocked(_ samples: [Float]) {
        guard !samples.isEmpty,
              let canonicalFormat,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: canonicalFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }

        updateMeter(samples: samples)

        if let audioFile {
            do {
                try audioFile.write(from: buffer)
            } catch {
                logger.error("Failed writing system audio buffer: \(error.localizedDescription, privacy: .public)")
            }
        }
        liveFeed?.send(buffer)
    }

    private func updateMeter(samples: [Float]) {
        var peak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(max(1, samples.count)))
        let peakDB = peak > 0.000_001 ? 20 * log10(peak) : -160
        let normalized = min(1.0, max(0.0, (rms * 4.0)))
        meterLock.lock()
        latestLevel = normalized
        latestPeakDecibels = peakDB
        meterLock.unlock()
    }

    // MARK: - Teardown

    private func stopCaptureHardware() {
        meterLock.lock()
        isCapturing = false
        latestLevel = 0
        latestPeakDecibels = -160
        meterLock.unlock()

        if let engine = micEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            micEngine = nil
        }
        micConverter = nil

        if let ioProcID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        self.ioProcID = nil

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapConverter = nil
    }

    private func teardown(deleteFile: Bool) async {
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
