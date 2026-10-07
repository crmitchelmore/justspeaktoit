import Foundation

/// Synthesized speech ready for a native file player: a RIFF/WAVE file of mono
/// 16-bit PCM whose 44-byte header exactly describes its payload.
struct DeepgramSpeechAudio: Equatable, Sendable {
    let wav: Data
    let sampleRate: Int
    let frameCount: Int

    var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
}

/// Reads the RIFF/WAVE body Deepgram returns for `container=wav`.
///
/// Deepgram streams speech as it is generated, so it writes the header before
/// the length is known. Only documented streaming sentinels are accepted as
/// "length unknown", and only as the RIFF/`data` pair they appear in:
/// - RIFF 0x7FFF0024 with `data` 0x7FFF0000, the header Deepgram returns
///   (hexdumps in https://developers.deepgram.com/docs/handling-audio-issues-in-text-to-speech
///   and https://github.com/orgs/deepgram/discussions/664, read 2026-09-22);
/// - RIFF 0 with `data` 0, the placeholders in Deepgram's own streamed-header
///   example on the same page.
/// The `data` chunk then runs to the end of the body. Any other length is
/// finite and must be consistent: the RIFF length must match the body, and a
/// declared length the body does not reach is truncated audio, never partial
/// speech. Anything other than mono 16-bit linear PCM at the requested rate is
/// refused rather than guessed, as are empty and entirely silent payloads. The
/// result is rewritten with exact lengths.
enum DeepgramSpeechWAV {
    private struct Sentinel: Equatable {
        let riff: UInt32
        let data: UInt32
    }

    private static let sentinels = [
        Sentinel(riff: 0x7FFF_0024, data: 0x7FFF_0000),
        Sentinel(riff: 0, data: 0)
    ]
    private static let extensibleFormat = 0xFFFE
    /// KSDATAFORMAT_SUBTYPE_PCM after its leading 16-bit format tag.
    private static let pcmSubformatTail: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    static func canonical(_ body: Data, sampleRate: Int) throws -> DeepgramSpeechAudio {
        guard !body.isEmpty else { throw DeepgramSpeechError.emptyAudio }
        guard body.count >= 12, fourCC(body, at: 0) == "RIFF", fourCC(body, at: 8) == "WAVE" else {
            throw DeepgramSpeechError.unsupportedAudioFormat
        }
        let riff = uint32(body, at: 4)
        let streamed = sentinels.first { $0.riff == riff }
        if streamed == nil {
            guard Int(riff) <= body.count - 8 else { throw DeepgramSpeechError.incompleteAudio }
            guard Int(riff) == body.count - 8 else { throw DeepgramSpeechError.unsupportedAudioFormat }
        }
        var offset = 12
        var hasFormat = false
        while offset <= body.count - 8 {
            let identifier = fourCC(body, at: offset)
            let declared = uint32(body, at: offset + 4)
            let start = offset + 8
            let available = body.count - start
            if identifier == "data" {
                guard hasFormat else { throw DeepgramSpeechError.unsupportedAudioFormat }
                let length = try dataLength(declared, available, streamed)
                return try audio(body[(body.startIndex + start)...].prefix(length), sampleRate: sampleRate)
            }
            guard Int(declared) <= available else { throw DeepgramSpeechError.incompleteAudio }
            if identifier == "fmt " {
                try validateFormat(body, start: start, length: Int(declared), sampleRate: sampleRate)
                hasFormat = true
            }
            // Chunks are word aligned: an odd length is followed by a pad byte.
            offset = start + Int(declared) + Int(declared & 1)
        }
        throw DeepgramSpeechError.unsupportedAudioFormat
    }

    /// A streamed header must carry its sentinel's `data` value, and its
    /// payload runs to the end of the body. A finite length must be present.
    private static func dataLength(_ declared: UInt32, _ available: Int, _ streamed: Sentinel?) throws -> Int {
        if let streamed {
            guard declared == streamed.data else { throw DeepgramSpeechError.unsupportedAudioFormat }
            return available
        }
        guard Int(declared) <= available else { throw DeepgramSpeechError.incompleteAudio }
        return Int(declared)
    }

    /// Linear PCM (plain or WAVE_FORMAT_EXTENSIBLE), one channel, the requested
    /// rate, two-byte frames of 16-bit samples.
    private static func validateFormat(_ body: Data, start: Int, length: Int, sampleRate: Int) throws {
        guard length >= 16 else { throw DeepgramSpeechError.unsupportedAudioFormat }
        let tag = uint16(body, at: start)
        let isPCM: Bool
        if tag == extensibleFormat {
            isPCM = length >= 40 && uint16(body, at: start + 24) == 1
                && body.dropFirst(start + 26).prefix(pcmSubformatTail.count).elementsEqual(pcmSubformatTail)
        } else {
            isPCM = tag == 1
        }
        guard isPCM,
              uint16(body, at: start + 2) == 1,
              Int(uint32(body, at: start + 4)) == sampleRate,
              uint16(body, at: start + 12) == 2,
              uint16(body, at: start + 14) == 16 else {
            throw DeepgramSpeechError.unsupportedAudioFormat
        }
    }

    private static func audio(_ pcm: Data, sampleRate: Int) throws -> DeepgramSpeechAudio {
        guard !pcm.isEmpty else { throw DeepgramSpeechError.emptyAudio }
        // A partial trailing sample means the stream did not end on a frame.
        guard pcm.count.isMultiple(of: 2) else { throw DeepgramSpeechError.unsupportedAudioFormat }
        guard pcm.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { throw DeepgramSpeechError.silentAudio }
        guard let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate) else {
            throw DeepgramSpeechError.unsupportedAudioFormat
        }
        return DeepgramSpeechAudio(wav: wav, sampleRate: sampleRate, frameCount: pcm.count / 2)
    }

    private static func fourCC(_ body: Data, at offset: Int) -> String {
        let lower = body.startIndex + offset
        return String(bytes: body[lower..<(lower + 4)], encoding: .ascii) ?? ""
    }

    private static func uint16(_ body: Data, at offset: Int) -> Int {
        let lower = body.startIndex + offset
        return Int(body[lower]) | Int(body[lower + 1]) << 8
    }

    private static func uint32(_ body: Data, at offset: Int) -> UInt32 {
        UInt32(uint16(body, at: offset)) | UInt32(uint16(body, at: offset + 2)) << 16
    }
}
