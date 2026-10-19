import Foundation
import SpeakCore
import CLinuxSupport

public enum LinuxVoiceAudioCodec {
    public static func requireAvailable(_ format: VoiceAudioFormat, sampleRate: Int) async throws {
        try Task.checkCancellation()
        guard VoiceSynthesisQuality.allCases.contains(where: { $0.sampleRate == sampleRate }) else {
            throw DeepgramSpeechError.unsupportedAudioFormat
        }
        guard format != .wav else { return }
        try await VoiceAudioCodecWorker.run { _ in
            var error = [CChar](repeating: 0, count: 1_024)
            let status = format.rawValue.withCString {
                jsti_voice_codec_available($0, UInt32(sampleRate), &error, error.count)
            }
            guard status == 0 else { throw VoiceAudioFormatError.unavailable(String(cString: error)) }
        }
    }

    public static func encode(
        _ audio: VoiceGeneratedAudio, format: VoiceAudioFormat
    ) async throws -> VoiceGeneratedAudio {
        try Task.checkCancellation()
        guard audio.format == .wav else { throw VoiceAudioFormatError.invalidContainer }
        guard format != .wav else { return audio }
        return try await VoiceAudioCodecWorker.run { cancellation in
            let capture = VoiceAudioCodecCapture(cancellation: cancellation)
            var error = [CChar](repeating: 0, count: 1_024)
            let status = withExtendedLifetime(capture) {
                audio.wav.dropFirst(44).withUnsafeBytes { pcm in
                    format.rawValue.withCString { identifier in
                        var request = JSTIVoiceCodecRequest(
                            format: identifier, sample_rate: UInt32(audio.sampleRate),
                            pcm: pcm.bindMemory(to: UInt8.self).baseAddress, pcm_bytes: pcm.count,
                            output: { kind, bytes, count, context in
                                guard let context else { return -1 }
                                return Unmanaged<VoiceAudioCodecCapture>.fromOpaque(context)
                                    .takeUnretainedValue().append(kind: kind, bytes: bytes, count: count)
                            }, cancelled: { context in
                                guard let context else { return 1 }
                                return Unmanaged<VoiceAudioCodecCapture>.fromOpaque(context)
                                    .takeUnretainedValue().cancellation.isCancelled ? 1 : 0
                            }, context: Unmanaged.passUnretained(capture).toOpaque())
                        return jsti_voice_codec_encode(&request, &error, error.count)
                    }
                }
            }
            if status == 1 || cancellation.isCancelled { throw CancellationError() }
            guard status == 0 else { throw VoiceAudioFormatError.unavailable(String(cString: error)) }
            return try capture.result(format: format, sampleRate: audio.sampleRate)
        }
    }
}
