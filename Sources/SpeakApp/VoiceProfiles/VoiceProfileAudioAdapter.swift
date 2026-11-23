@preconcurrency import AVFoundation
import Foundation
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

    private struct ConversionSetup {
        let converter: AVAudioConverter
        let inputBuffer: AVAudioPCMBuffer
        let outputBuffer: AVAudioPCMBuffer
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
    ) throws -> ConversionSetup {
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
        return ConversionSetup(converter: converter, inputBuffer: inputBuffer, outputBuffer: outputBuffer)
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
