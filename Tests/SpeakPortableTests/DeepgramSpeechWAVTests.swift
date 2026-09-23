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

    /// The header Deepgram streams before synthesis ends: RIFF `24 00 ff 7f`
    /// and data `00 00 ff 7f`, as in the hexdumps at
    /// https://developers.deepgram.com/docs/handling-audio-issues-in-text-to-speech
    /// and https://github.com/orgs/deepgram/discussions/664.
    static func streamedWAV(pcm: Data, rate: Int = 24_000) -> Data {
        withLengths(canonicalWAV(pcm: pcm, rate: rate), riff: [0x24, 0x00, 0xFF, 0x7F], data: [0x00, 0x00, 0xFF, 0x7F])
    }

    /// The zero placeholders in Deepgram's streamed-header example.
    static func zeroPlaceholderWAV(pcm: Data, rate: Int = 24_000) -> Data {
        withLengths(canonicalWAV(pcm: pcm, rate: rate), riff: [0, 0, 0, 0], data: [0, 0, 0, 0])
    }

    /// Replaces the RIFF and `data` length bytes of a 44-byte-header WAV.
    static func withLengths(_ wav: Data, riff: [UInt8], data: [UInt8]) -> Data {
        var wav = wav
        wav.replaceSubrange(4..<8, with: riff)
        wav.replaceSubrange(40..<44, with: data)
        return wav
    }

    /// Recomputes a finite RIFF length for the whole body.
    static func withFiniteRIFF(_ body: Data) -> Data {
        var body = body
        body.replaceSubrange(4..<8, with: littleEndian(UInt32(body.count - 8)))
        return body
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
    private var expected: Data { DeepgramSpeechFixture.canonicalWAV(pcm: pcm) }

    func testDocumentedDeepgramStreamingHeaders_AreRewrittenExactly() throws {
        let streamed = DeepgramSpeechFixture.streamedWAV(pcm: pcm)
        XCTAssertEqual(Array(streamed[4..<8]), [0x24, 0x00, 0xFF, 0x7F])
        XCTAssertEqual(Array(streamed[40..<44]), [0x00, 0x00, 0xFF, 0x7F])
        for body in [streamed, DeepgramSpeechFixture.zeroPlaceholderWAV(pcm: pcm)] {
            let audio = try DeepgramSpeechWAV.canonical(body, sampleRate: 24_000)
            XCTAssertEqual(audio.wav, expected)
            XCTAssertEqual(audio.frameCount, 2_400)
            XCTAssertEqual(audio.duration, 0.1, accuracy: 1e-12)
        }
        // An exact finite header passes through unchanged.
        XCTAssertEqual(try DeepgramSpeechWAV.canonical(expected, sampleRate: 24_000).wav, expected)
    }

    func testTruncatedFiniteAudio_IsIncompleteNeverPartialSpeech() {
        let declared = Array(DeepgramSpeechFixture.littleEndian(UInt32(pcm.count + 2)))
        let consistentRIFF = Array(DeepgramSpeechFixture.littleEndian(UInt32(36 + pcm.count + 2)))
        // Both lengths finite and consistent with each other, but the body ends early.
        assertRefused(expected.dropLast(100), .incompleteAudio, "cut mid-payload")
        assertRefused(
            DeepgramSpeechFixture.withLengths(expected, riff: consistentRIFF, data: declared),
            .incompleteAudio, "declared beyond the body"
        )
        // The RIFF length matches the body but the data length overruns it.
        assertRefused(
            DeepgramSpeechFixture.withLengths(expected, riff: Array(expected[4..<8]), data: declared),
            .incompleteAudio, "data beyond a consistent RIFF"
        )
        // 0xFFFFFFFF is not a documented Deepgram sentinel; it is an overrun.
        assertRefused(
            DeepgramSpeechFixture.withLengths(expected, riff: [0xFF, 0xFF, 0xFF, 0xFF], data: [0xFF, 0xFF, 0xFF, 0xFF]),
            .incompleteAudio, "undocumented all-ones lengths"
        )
        // The stream ended inside the header.
        let header = Data("RIFF".utf8) + DeepgramSpeechFixture.littleEndian(0) + Data("WAVEfmt ".utf8)
        assertRefused(header + DeepgramSpeechFixture.littleEndian(16) + Data([1, 0, 1, 0]), .incompleteAudio, "fmt")
    }

    func testInconsistentOrMixedLengths_AreRefused() {
        let finiteData = Array(expected[40..<44])
        let cases: [(String, Data)] = [
            ("bytes after the RIFF container", expected + Data([1, 2, 3, 4])),
            ("Deepgram RIFF sentinel with a finite data length",
             DeepgramSpeechFixture.withLengths(expected, riff: [0x24, 0x00, 0xFF, 0x7F], data: finiteData)),
            ("zero RIFF with Deepgram's data sentinel",
             DeepgramSpeechFixture.withLengths(expected, riff: [0, 0, 0, 0], data: [0x00, 0x00, 0xFF, 0x7F])),
            ("Deepgram RIFF sentinel with a zero data length",
             DeepgramSpeechFixture.withLengths(expected, riff: [0x24, 0x00, 0xFF, 0x7F], data: [0, 0, 0, 0]))
        ]
        for (name, body) in cases {
            assertRefused(body, .unsupportedAudioFormat, name)
        }
        // A finite RIFF with Deepgram's data sentinel declares more than arrived.
        assertRefused(
            DeepgramSpeechFixture.withLengths(expected, riff: Array(expected[4..<8]), data: [0x00, 0x00, 0xFF, 0x7F]),
            .incompleteAudio, "finite RIFF with a data sentinel"
        )
    }

    func testOtherChunksAndExtensiblePCM_AreAcceptedWithoutTheirBytes() throws {
        // An odd-sized LIST chunk and its pad byte precede the audio; a trailing
        // chunk follows an exact data length inside a consistent RIFF length.
        var body = Data(expected[0..<36])
        body.append(Data("LIST".utf8) + DeepgramSpeechFixture.littleEndian(3) + Data([1, 2, 3, 0]))
        body.append(expected[36...])
        body.append(Data("junk".utf8) + DeepgramSpeechFixture.littleEndian(2) + Data([9, 9]))
        XCTAssertEqual(try canonical(DeepgramSpeechFixture.withFiniteRIFF(body)), expected)

        let streamedLengths: [([UInt8], [UInt8])] = [
            ([0x24, 0x00, 0xFF, 0x7F], [0x00, 0x00, 0xFF, 0x7F]), ([0, 0, 0, 0], [0, 0, 0, 0])
        ]
        for (riff, data) in streamedLengths {
            XCTAssertEqual(try canonical(extensible(riff: riff, data: data)), expected)
        }
        let finite = extensible(riff: [0, 0, 0, 0], data: Array(DeepgramSpeechFixture.littleEndian(UInt32(pcm.count))))
        XCTAssertEqual(try canonical(DeepgramSpeechFixture.withFiniteRIFF(finite)), expected)
    }

    private func canonical(_ body: Data) throws -> Data {
        try DeepgramSpeechWAV.canonical(body, sampleRate: 24_000).wav
    }

    func testEmptyAndSilentResponses_AreRefused() {
        assertRefused(Data(), .emptyAudio)
        assertRefused(DeepgramSpeechFixture.zeroPlaceholderWAV(pcm: Data()), .emptyAudio)
        assertRefused(DeepgramSpeechFixture.streamedWAV(pcm: Data()), .emptyAudio)
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
            ("no data chunk", DeepgramSpeechFixture.withFiniteRIFF(Data(expected[0..<36]))),
            ("data before fmt", Data(expected[0..<12]) + Data(expected[36...]) + Data(expected[12..<36]))
        ]
        for (name, body) in unsupported {
            assertRefused(body, .unsupportedAudioFormat, name)
        }
    }

    private func extensible(riff: [UInt8], data: [UInt8]) -> Data {
        var format = DeepgramSpeechFixture.littleEndian16(0xFFFE) + DeepgramSpeechFixture.littleEndian16(1)
        format += DeepgramSpeechFixture.littleEndian(24_000) + DeepgramSpeechFixture.littleEndian(48_000)
        format += DeepgramSpeechFixture.littleEndian16(2) + DeepgramSpeechFixture.littleEndian16(16)
        format += DeepgramSpeechFixture.littleEndian16(22) + DeepgramSpeechFixture.littleEndian16(16)
        format += DeepgramSpeechFixture.littleEndian(4)
        format += Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        var body = Data("RIFF".utf8) + Data(riff) + Data("WAVEfmt ".utf8)
        body += DeepgramSpeechFixture.littleEndian(UInt32(format.count)) + format
        body += Data("data".utf8) + Data(data) + pcm
        return body
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
