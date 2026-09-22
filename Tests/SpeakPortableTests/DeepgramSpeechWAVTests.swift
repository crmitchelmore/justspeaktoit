import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// Deterministic synthetic Deepgram responses. No speech, recordings or keys.
enum DeepgramSpeechFixture {
    /// A quiet 200 Hz square wave, the same shape as the Windows playback tests.
    static func pcm(frames: Int, rate: Int = 24_000) -> Data {
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let sample = UInt16(bitPattern: (frame / (rate / 400)).isMultiple(of: 2) ? 512 : -512)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return pcm
    }

    /// The canonical 44-byte header and payload, as a player should receive it.
    static func canonicalWAV(pcm: Data, rate: Int = 24_000, channels: Int = 1, bits: Int = 16) -> Data {
        PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate, channels: channels, bitsPerSample: bits)!
    }

    /// A streamed response: its header was written before synthesis ended, so
    /// both lengths carry `placeholder`.
    static func streamedWAV(pcm: Data, rate: Int = 24_000, placeholder: UInt32 = .max) -> Data {
        var wav = canonicalWAV(pcm: pcm, rate: rate)
        wav.replaceSubrange(4..<8, with: littleEndian(placeholder))
        wav.replaceSubrange(40..<44, with: littleEndian(placeholder))
        return wav
    }

    static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }

    static func littleEndian16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// Every stubbed reply declares a content type; URLSession otherwise holds
    /// an untyped response back for MIME sniffing.
    static func response(
        _ request: URLRequest, status: Int = 200, headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        let fields = headers.merging(["Content-Type": "audio/wav"]) { explicit, _ in explicit }
        return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: fields)!
    }
}

final class DeepgramSpeechWAVTests: XCTestCase {
    private let pcm = DeepgramSpeechFixture.pcm(frames: 2_400)

    func testStreamedPlaceholderLengths_AreRewrittenExactly() throws {
        let expected = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        for placeholder in [UInt32.max, 0] {
            let body = DeepgramSpeechFixture.streamedWAV(pcm: pcm, placeholder: placeholder)
            let audio = try DeepgramSpeechWAV.canonical(body, sampleRate: 24_000)
            XCTAssertEqual(audio.wav, expected, "placeholder \(placeholder)")
            XCTAssertEqual(audio.frameCount, 2_400)
            XCTAssertEqual(audio.duration, 0.1, accuracy: 1e-12)
        }
        // A data length beyond the received bytes is a placeholder too.
        var oversized = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        oversized.replaceSubrange(40..<44, with: DeepgramSpeechFixture.littleEndian(10_000_000))
        XCTAssertEqual(try DeepgramSpeechWAV.canonical(oversized, sampleRate: 24_000).wav, expected)
        // An exact header passes through unchanged.
        XCTAssertEqual(try DeepgramSpeechWAV.canonical(expected, sampleRate: 24_000).wav, expected)
    }

    func testOtherChunksAndExtensiblePCM_AreAcceptedWithoutTheirBytes() throws {
        let expected = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        // An odd-sized LIST chunk and its pad byte precede the audio; a trailing
        // chunk follows an exact data length. Neither reaches the player.
        var body = Data(expected[0..<36])
        body.append(Data("LIST".utf8) + DeepgramSpeechFixture.littleEndian(3) + Data([1, 2, 3, 0]))
        body.append(expected[36...])
        body.append(Data("junk".utf8) + DeepgramSpeechFixture.littleEndian(2) + Data([9, 9]))
        XCTAssertEqual(try DeepgramSpeechWAV.canonical(body, sampleRate: 24_000).wav, expected)

        XCTAssertEqual(try DeepgramSpeechWAV.canonical(extensible(), sampleRate: 24_000).wav, expected)
    }

    func testEmptyAndSilentResponses_AreRefused() {
        assertRefused(Data(), .emptyAudio)
        assertRefused(DeepgramSpeechFixture.streamedWAV(pcm: Data(), placeholder: 0), .emptyAudio)
        assertRefused(DeepgramSpeechFixture.canonicalWAV(pcm: Data()), .emptyAudio)
        assertRefused(DeepgramSpeechFixture.streamedWAV(pcm: Data(count: 4_800)), .silentAudio)
    }

    func testOtherFormatsAndMalformedContainers_AreRefusedRatherThanGuessed() {
        let unsupported: [(String, Data)] = [
            ("JSON error body", Data(#"{"err_code":"INVALID"}"#.utf8)),
            ("MP3 frames", Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0x64] + [UInt8](pcm))),
            ("16 kHz", DeepgramSpeechFixture.canonicalWAV(pcm: pcm, rate: 16_000)),
            ("48 kHz", DeepgramSpeechFixture.canonicalWAV(pcm: pcm, rate: 48_000)),
            ("stereo", DeepgramSpeechFixture.canonicalWAV(pcm: pcm, channels: 2)),
            ("8-bit", DeepgramSpeechFixture.canonicalWAV(pcm: pcm, bits: 8)),
            ("partial sample", DeepgramSpeechFixture.streamedWAV(pcm: pcm) + Data([7])),
            ("no data chunk", Data(DeepgramSpeechFixture.canonicalWAV(pcm: pcm)[0..<36])),
            ("data before fmt", dataBeforeFormat()),
            ("truncated fmt", Data("RIFF".utf8) + DeepgramSpeechFixture.littleEndian(0) + Data("WAVEfmt ".utf8)
                + DeepgramSpeechFixture.littleEndian(16) + Data([1, 0, 1, 0]))
        ]
        for (name, body) in unsupported {
            assertRefused(body, .unsupportedAudioFormat, name)
        }
    }

    private func extensible() -> Data {
        var format = DeepgramSpeechFixture.littleEndian16(0xFFFE) + DeepgramSpeechFixture.littleEndian16(1)
        format += DeepgramSpeechFixture.littleEndian(24_000) + DeepgramSpeechFixture.littleEndian(48_000)
        format += DeepgramSpeechFixture.littleEndian16(2) + DeepgramSpeechFixture.littleEndian16(16)
        format += DeepgramSpeechFixture.littleEndian16(22) + DeepgramSpeechFixture.littleEndian16(16)
        format += DeepgramSpeechFixture.littleEndian(4)
        format += Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        var body = Data("RIFF".utf8) + DeepgramSpeechFixture.littleEndian(.max) + Data("WAVEfmt ".utf8)
        body += DeepgramSpeechFixture.littleEndian(UInt32(format.count)) + format
        body += Data("data".utf8) + DeepgramSpeechFixture.littleEndian(.max) + pcm
        return body
    }

    private func dataBeforeFormat() -> Data {
        let canonical = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        return Data(canonical[0..<12]) + Data(canonical[36...]) + Data(canonical[12..<36])
    }

    private func assertRefused(
        _ body: Data, _ expected: DeepgramSpeechError, _ name: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try DeepgramSpeechWAV.canonical(body, sampleRate: 24_000), name, file: file, line: line) {
            XCTAssertEqual($0 as? DeepgramSpeechError, expected, name, file: file, line: line)
        }
    }
}
