import Foundation
import SpeakCore

/// Voice export encoding through the native codec ABI shared by Windows and
/// Linux (`VoiceAudioCodec.h`). Each host supplies only its two C entry points,
/// which capture no state, so sharing it is safe.
public struct DesktopVoiceAudioCodec: @unchecked Sendable {
    /// `JSTIVoiceCodecOutput` and `JSTIVoiceCodecCancelled`.
    public typealias Output = @convention(c) (Int32, UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Int32
    public typealias Cancelled = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// One synchronous request; every pointer is borrowed until it returns.
    public struct Request {
        public let format: UnsafePointer<CChar>
        public let sampleRate: UInt32
        public let pcm: UnsafePointer<UInt8>?
        public let pcmBytes: Int
        public let output: Output
        public let cancelled: Cancelled
        public let context: UnsafeMutableRawPointer
    }

    /// `jsti_voice_codec_available`: 0 available, otherwise the reason in `error`.
    public let available: (
        _ format: UnsafePointer<CChar>, _ sampleRate: UInt32, _ error: UnsafeMutablePointer<CChar>, _ capacity: Int
    ) -> Int32
    /// Builds the native request and runs `jsti_voice_codec_encode`: 0 success, 1 cancelled.
    public let encodeRequest: (
        _ request: Request, _ error: UnsafeMutablePointer<CChar>, _ capacity: Int
    ) -> Int32

    public init(
        available: @escaping (UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<CChar>, Int) -> Int32,
        encode: @escaping (Request, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) {
        self.available = available
        self.encodeRequest = encode
    }

    public func requireAvailable(_ format: VoiceAudioFormat, sampleRate: Int) async throws {
        try Task.checkCancellation()
        guard VoiceSynthesisQuality.allCases.contains(where: { $0.sampleRate == sampleRate }) else {
            throw DeepgramSpeechError.unsupportedAudioFormat
        }
        guard format != .wav else { return }
        let codec = self
        try await VoiceAudioCodecWorker.run { _ in
            var error = [CChar](repeating: 0, count: 1_024)
            let status = format.rawValue.withCString { codec.available($0, UInt32(sampleRate), &error, error.count) }
            guard status == 0 else { throw VoiceAudioFormatError.unavailable(String(cString: error)) }
        }
    }

    public func encode(_ audio: VoiceGeneratedAudio, format: VoiceAudioFormat) async throws -> VoiceGeneratedAudio {
        try Task.checkCancellation()
        guard audio.format == .wav else { throw VoiceAudioFormatError.invalidContainer }
        guard format != .wav else { return audio }
        let codec = self
        return try await VoiceAudioCodecWorker.run { cancellation in
            let capture = VoiceAudioCodecCapture(cancellation: cancellation)
            var error = [CChar](repeating: 0, count: 1_024)
            let status = NativeCallbackContext.withScoped(capture) { context in
                audio.wav.dropFirst(44).withUnsafeBytes { pcm in
                    format.rawValue.withCString { identifier in
                        codec.encodeRequest(Request(
                            format: identifier, sampleRate: UInt32(audio.sampleRate),
                            pcm: pcm.bindMemory(to: UInt8.self).baseAddress, pcmBytes: pcm.count,
                            output: { kind, bytes, count, context in
                                NativeCallbackContext<VoiceAudioCodecCapture>.resolve(context)?
                                    .append(kind: kind, bytes: bytes, count: count) ?? -1
                            }, cancelled: { context in
                                guard let capture = NativeCallbackContext<VoiceAudioCodecCapture>.resolve(context)
                                else { return 1 }
                                return capture.cancellation.isCancelled ? 1 : 0
                            }, context: context
                        ), &error, error.count)
                    }
                }
            }
            if status == 1 || cancellation.isCancelled { throw CancellationError() }
            guard status == 0 else { throw VoiceAudioFormatError.unavailable(String(cString: error)) }
            return try capture.result(format: format, sampleRate: audio.sampleRate)
        }
    }
}
