import AppKit
@preconcurrency import AVFoundation
import Foundation
import os
import SpeakCore

/// Errors raised during macOS audio decoding or live voice-profile microphone capture.
enum VoiceProfileAudioAdapterError: LocalizedError, Equatable {
    case unsupportedFileFormat
    case fileTooLong(TimeInterval)
    case emptyAudio
    case microphonePermissionDenied
    case audioInputUnavailable
    case alreadyRecording
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFileFormat:
            "This audio file format could not be decoded. Choose a WAV, M4A, or MP3 file."
        case .fileTooLong(let maximum):
            "Audio file exceeds the \(Int(maximum / 60))-minute import limit."
        case .emptyAudio:
            "The selected audio file contains no audio samples."
        case .microphonePermissionDenied:
            "Microphone permission is required to record a voice profile. Allow access in System Settings."
        case .audioInputUnavailable:
            "No usable microphone input is currently available."
        case .alreadyRecording:
            "A voice profile recording is already in progress."
        case .conversionFailed:
            "Could not convert the audio file to mono WAV."
        }
    }
}

/// Decodes WAV, M4A, MP3 and other AVFoundation-supported audio files into mono PCM buffers.
enum VoiceProfileAudioAdapter {
    private enum OpenedAudio {
        case avAudioFile(AVAudioFile, duration: TimeInterval)
        case preDecodedWAV(VoiceProfilePCMBuffer)
    }

    static func decodeAudioFile(
        at url: URL,
        targetFormat: VoiceProfileAudioFormat = .pcm24k,
        maximumDuration: TimeInterval = 900
    ) throws -> VoiceProfilePCMBuffer {
        switch try openAudioFile(at: url, targetFormat: targetFormat, maximumDuration: maximumDuration) {
        case .preDecodedWAV(let buffer):
            return buffer
        case .avAudioFile(let file, let duration):
            let setup = try makeConverterAndBuffers(inputFormat: file.processingFormat, targetFormat: targetFormat)
            let expectedFrames = Int((duration * Double(targetFormat.sampleRate)).rounded(.up))
            let cappedCapacity = max(0, min(expectedFrames, targetFormat.sampleRate * Int(maximumDuration)))
            let samples = try drainConvertedSamples(
                from: file,
                converter: setup.converter,
                inputBuffer: setup.inputBuffer,
                outputBuffer: setup.outputBuffer,
                expectedFrames: cappedCapacity
            )
            guard !samples.isEmpty else { throw VoiceProfileAudioAdapterError.emptyAudio }
            return VoiceProfilePCMBuffer(samples: samples, sampleRate: targetFormat.sampleRate)
        }
    }

    private static func openAudioFile(
        at url: URL,
        targetFormat: VoiceProfileAudioFormat,
        maximumDuration: TimeInterval
    ) throws -> OpenedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            if url.pathExtension.lowercased() == "wav" {
                let decoded = try VoiceProfileWAVCodec.decodeWAV(at: url)
                return .preDecodedWAV(VoiceProfileWAVCodec.resample(decoded, to: targetFormat))
            }
            throw VoiceProfileAudioAdapterError.unsupportedFileFormat
        }

        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceProfileAudioAdapterError.unsupportedFileFormat
        }
        let duration = Double(file.length) / inputFormat.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw VoiceProfileAudioAdapterError.emptyAudio
        }
        guard duration <= maximumDuration else {
            throw VoiceProfileAudioAdapterError.fileTooLong(maximumDuration)
        }
        return .avAudioFile(file, duration: duration)
    }

    private static func makeConverterAndBuffers(
        inputFormat: AVAudioFormat,
        targetFormat: VoiceProfileAudioFormat
    ) throws -> (converter: AVAudioConverter, inputBuffer: AVAudioPCMBuffer, outputBuffer: AVAudioPCMBuffer) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetFormat.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192),
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            throw VoiceProfileAudioAdapterError.conversionFailed
        }
        return (converter, inputBuffer, outputBuffer)
    }

    private static func drainConvertedSamples(
        from file: AVAudioFile,
        converter: AVAudioConverter,
        inputBuffer: AVAudioPCMBuffer,
        outputBuffer: AVAudioPCMBuffer,
        expectedFrames: Int
    ) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(expectedFrames)

        var finished = false
        while !finished {
            let status = try convertNextChunk(
                from: file,
                converter: converter,
                inputBuffer: inputBuffer,
                outputBuffer: outputBuffer
            )
            let frameCount = Int(outputBuffer.frameLength)
            if frameCount > 0, let channelData = outputBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))
            }
            finished = status == .endOfStream
            guard finished || frameCount > 0 else { throw VoiceProfileAudioAdapterError.conversionFailed }
        }
        return samples
    }

    private static func convertNextChunk(
        from file: AVAudioFile,
        converter: AVAudioConverter,
        inputBuffer: AVAudioPCMBuffer,
        outputBuffer: AVAudioPCMBuffer
    ) throws -> AVAudioConverterOutputStatus {
        var readError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard file.framePosition < file.length else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: inputBuffer)
                inputStatus.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                return inputBuffer.frameLength == 0 ? nil : inputBuffer
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        guard status != .error else { throw VoiceProfileAudioAdapterError.conversionFailed }
        return status
    }

    static func writeTemporaryPreviewWAV(for buffer: VoiceProfilePCMBuffer) throws -> URL {
        let format: VoiceProfileAudioFormat = buffer.sampleRate == 16_000 ? .pcm16k : .pcm24k
        let wavData = try VoiceProfileWAVCodec.encodeWAV(buffer, format: format)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-preview-\(UUID().uuidString).wav", isDirectory: false)
        try wavData.write(to: url, options: .atomic)
        return url
    }
}

private final class VoiceProfileCaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Int
    private var samples: [Float] = []
    private var latestPeak: Float = 0
    private var latestRMS: Float = 0
    private var totalClippedCount = 0
    private var clippingInWindow = false

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        samples.reserveCapacity(sampleRate * 20)
    }

    func append(buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0, let channels = buffer.floatChannelData else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        var peak: Float = 0
        var sumSquares = 0.0
        var clipped = 0
        let scale = 1.0 / Float(channelCount)

        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += channels[channelIndex][frameIndex]
            }
            let sample = max(-1.0, min(1.0, sum * scale))
            mono[frameIndex] = sample
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            if magnitude >= 0.985 { clipped += 1 }
            sumSquares += Double(sample) * Double(sample)
        }
        let rms = Float(sqrt(sumSquares / Double(frameCount)))

        lock.lock()
        samples.append(contentsOf: mono)
        latestPeak = peak
        latestRMS = rms
        totalClippedCount += clipped
        if clipped > 0 { clippingInWindow = true }
        lock.unlock()
    }

    struct MeterSnapshot {
        let elapsedSeconds: TimeInterval
        let level: Float
        let peakDecibels: Float
        let isClipping: Bool
        let totalClipped: Int
    }

    func meterSnapshot() -> MeterSnapshot {
        lock.lock()
        let count = samples.count
        let peak = latestPeak
        let rms = latestRMS
        let clipping = clippingInWindow
        let totalClipped = totalClippedCount
        clippingInWindow = false
        lock.unlock()

        let elapsed = sampleRate > 0 ? Double(count) / Double(sampleRate) : 0
        let peakDB: Float = peak > 1e-6 ? max(-100, 20 * log10(peak)) : -100
        let rmsDB: Float = rms > 1e-6 ? max(-100, 20 * log10(rms)) : -100
        let combinedDB = (rmsDB * 0.7) + (peakDB * 0.3)
        let normalizedLevel = max(0, min(1, (combinedDB + 60) / 60))
        return MeterSnapshot(
            elapsedSeconds: elapsed,
            level: normalizedLevel,
            peakDecibels: peakDB,
            isClipping: clipping || peak >= 0.985,
            totalClipped: totalClipped
        )
    }

    func drainBuffer() -> VoiceProfilePCMBuffer {
        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return VoiceProfilePCMBuffer(samples: captured, sampleRate: sampleRate)
    }
}

/// Captures a guided voice-profile microphone clip with live level and clipping telemetry.
@MainActor
final class VoiceProfileRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var peakDecibels: Float = -100
    @Published private(set) var isClipping = false
    @Published private(set) var clippedSampleCount = 0
    @Published var errorMessage: String?

    private let permissionsManager: PermissionsManager
    private let audioDeviceManager: AudioInputDeviceManager
    private let accessibilityAnnouncer: (String) -> Void

    private var audioEngine: AVAudioEngine?
    private var accumulator: VoiceProfileCaptureAccumulator?
    private var inputSession: AudioInputDeviceManager.SessionContext?
    private var meterTask: Task<Void, Never>?
    private var lastClipAnnouncementAt: Date = .distantPast
    private var onAutoStop: ((VoiceProfilePCMBuffer) -> Void)?

    init(
        permissionsManager: PermissionsManager,
        audioDeviceManager: AudioInputDeviceManager,
        accessibilityAnnouncer: @escaping (String) -> Void = VoiceProfileRecorder.postVoiceOverAnnouncement
    ) {
        self.permissionsManager = permissionsManager
        self.audioDeviceManager = audioDeviceManager
        self.accessibilityAnnouncer = accessibilityAnnouncer
    }

    func startRecording(onAutoStop: ((VoiceProfilePCMBuffer) -> Void)? = nil) async throws {
        guard !isRecording else { throw VoiceProfileAudioAdapterError.alreadyRecording }
        errorMessage = nil

        let permission = await permissionsManager.ensureGranted(.microphone)
        guard permission.isGranted else {
            let error = VoiceProfileAudioAdapterError.microphonePermissionDenied
            errorMessage = error.localizedDescription
            accessibilityAnnouncer("Microphone permission is required to record a voice sample.")
            throw error
        }

        let session = await audioDeviceManager.beginUsingPreferredInput()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard audioInputFormatIsUsable(hardwareFormat) else {
            await audioDeviceManager.endUsingPreferredInput(session: session)
            let error = VoiceProfileAudioAdapterError.audioInputUnavailable
            errorMessage = error.localizedDescription
            accessibilityAnnouncer("No usable microphone input is available.")
            throw error
        }

        let captureAccumulator = VoiceProfileCaptureAccumulator(sampleRate: Int(hardwareFormat.sampleRate.rounded()))
        do {
            try inputNode.installTapSafely(onBus: 0, bufferSize: 2_048, format: hardwareFormat) { buffer, _ in
                captureAccumulator.append(buffer: buffer)
            }
            try await startAudioEngineAfterInputDeviceSettles(engine)
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            await audioDeviceManager.endUsingPreferredInput(session: session)
            errorMessage = error.localizedDescription
            accessibilityAnnouncer("Could not start voice profile recording.")
            throw error
        }

        self.audioEngine = engine
        self.accumulator = captureAccumulator
        self.inputSession = session
        self.onAutoStop = onAutoStop
        elapsedSeconds = 0
        level = 0
        peakDecibels = -100
        isClipping = false
        clippedSampleCount = 0
        isRecording = true
        accessibilityAnnouncer("Recording voice sample started.")
        startMeterLoop()
    }

    func stopRecording(targetFormat: VoiceProfileAudioFormat = .pcm24k) async -> VoiceProfilePCMBuffer? {
        guard isRecording else { return nil }
        let raw = await tearDownCapture()
        accessibilityAnnouncer("Recording voice sample stopped.")
        guard !raw.samples.isEmpty else { return nil }
        return VoiceProfileWAVCodec.resample(raw, to: targetFormat)
    }

    func cancelRecording() async {
        guard isRecording else { return }
        _ = await tearDownCapture()
        accessibilityAnnouncer("Recording voice sample cancelled.")
    }

    private func startMeterLoop() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.isRecording, let accumulator = self.accumulator else { return }
                let snapshot = accumulator.meterSnapshot()
                self.elapsedSeconds = snapshot.elapsedSeconds
                self.level = snapshot.level
                self.peakDecibels = snapshot.peakDecibels
                self.isClipping = snapshot.isClipping
                self.clippedSampleCount = snapshot.totalClipped

                if snapshot.isClipping, Date().timeIntervalSince(self.lastClipAnnouncementAt) > 2.5 {
                    self.lastClipAnnouncementAt = Date()
                    self.accessibilityAnnouncer("Audio clipping detected. Move slightly away from the microphone.")
                }

                if snapshot.elapsedSeconds >= VoiceProfile.maximumClipDuration {
                    if let buffer = await self.stopRecording(targetFormat: .pcm24k) {
                        self.onAutoStop?(buffer)
                    }
                    return
                }
            }
        }
    }

    private func tearDownCapture() async -> VoiceProfilePCMBuffer {
        meterTask?.cancel()
        meterTask = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        let captured = accumulator?.drainBuffer() ?? VoiceProfilePCMBuffer(samples: [], sampleRate: 24_000)
        accumulator = nil
        isRecording = false
        level = 0
        if let session = inputSession {
            inputSession = nil
            await audioDeviceManager.endUsingPreferredInput(session: session)
        }
        return captured
    }

    nonisolated static func postVoiceOverAnnouncement(_ message: String) {
        Task { @MainActor in
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }
}
