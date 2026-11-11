import Foundation

/// Borrowed only by one synchronous native call, on its awaited worker.
public final class VoiceAudioCodecCapture {
    public let cancellation: VoiceAudioCodecWorker.Cancellation
    private var encoded = Data()
    private var pcm = Data()

    public init(cancellation: VoiceAudioCodecWorker.Cancellation) { self.cancellation = cancellation }

    public func append(kind: Int32, bytes: UnsafePointer<UInt8>?, count: Int) -> Int32 {
        guard !cancellation.isCancelled, count >= 0, let bytes else { return -1 }
        switch kind {
        case 0:
            guard encoded.isEmpty, count <= DeepgramSpeechExport.maximumPCMBytes + 4_096 else { return -1 }
            encoded.append(bytes, count: count)
        case 1:
            guard count % 2 == 0, count <= DeepgramSpeechExport.maximumPCMBytes - pcm.count else { return -1 }
            pcm.append(bytes, count: count)
        default: return -1
        }
        return 0
    }

    public func result(format: VoiceAudioFormat, sampleRate: Int) throws -> VoiceGeneratedAudio {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate) else {
            throw VoiceAudioFormatError.invalidContainer
        }
        return try .init(encoded: encoded, format: format, decodedWAV: wav, sampleRate: sampleRate)
    }
}
