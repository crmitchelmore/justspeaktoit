#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation
import XCTest

@testable import SpeakCore

final class IncrementalMP3DecoderTests: XCTestCase {
    private struct DecodedOutput {
        let pcm: Data
        let producedBeforeEOF: Bool
        let chunks: [Data]
    }

    func testRealMP3FragmentsPreservePCMAndProduceBeforeEOF() async throws {
        let mp3 = try fixture()
        let reference = try await decode(mp3, chunkSize: 1024)
        XCTAssertFalse(reference.pcm.isEmpty)
        XCTAssertTrue(reference.producedBeforeEOF)
        XCTAssertTrue(reference.pcm.contains { $0 != 0 })
        for size in [1, 7, 127] {
            let fragmented = try await decode(mp3, chunkSize: size)
            XCTAssertEqual(fragmented.pcm, reference.pcm, "MP3 reservoir state must survive fragment size \(size)")
            XCTAssertEqual(fragmented.chunks, reference.chunks)
            XCTAssertTrue(fragmented.producedBeforeEOF)
        }
    }

    func testMixedNetworkFragmentsKeepTheSamePCMOrderAndPreEOFOutput() async throws {
        let bytes = try fixture()
        let expected = try await decode(bytes, chunkSize: 1024)
        let mixed = try await decode(bytes, chunkSize: 1024, pattern: [1, 7, 1024, 3, 127, 511])
        XCTAssertEqual(mixed.pcm, expected.pcm)
        XCTAssertEqual(mixed.chunks, expected.chunks)
        XCTAssertTrue(mixed.producedBeforeEOF)
    }

    func testStereoDownmixRetainsRightChannelAndDoesNotOverflow() throws {
        let stereo = Data([0, 0, 255, 127, 0, 128, 0, 128, 255, 127, 255, 127, 0, 128, 255, 127])
        XCTAssertEqual(
            try IncrementalMP3NativeState.monoPCM(stereo, channels: 2),
            Data([255, 63, 0, 128, 255, 127, 0, 0])
        )
        XCTAssertThrowsError(try IncrementalMP3NativeState.monoPCM(Data([0]), channels: 2))
    }

    func testEmptyAppendDoesNotFlushOrEndTheNativeStream() async throws {
        let bytes = try fixture()
        let expected = try await decode(bytes, chunkSize: 1024)
        let decoder = IncrementalMP3Decoder()
        var pcm = Data()
        do {
            for byte in bytes {
                try await decoder.append(Data())
                try await decoder.append(Data([byte]))
                while let chunk = try await decoder.nextPCM() { pcm.append(chunk) }
            }
            try await decoder.finishInput()
            while let chunk = try await decoder.nextPCM() { pcm.append(chunk) }
            XCTAssertEqual(pcm, expected.pcm)
            await decoder.close()
        } catch {
            await decoder.close()
            throw error
        }
    }

    func testFinishedAndClosedDecoderCannotAcceptEmptyOrNewInput() async throws {
        let bytes = try fixture()
        let decoder = IncrementalMP3Decoder()
        for offset in stride(from: 0, to: bytes.count, by: 1024) {
            try await decoder.append(bytes.subdata(in: offset..<min(offset + 1024, bytes.count)))
            while try await decoder.nextPCM() != nil { }
        }
        try await decoder.finishInput()
        do {
            try await decoder.finishInput()
            XCTFail("EOF must be signalled only once")
        } catch { }
        do {
            try await decoder.append(Data())
            XCTFail("Even an empty append must respect finished state")
        } catch { }
        await decoder.close()
        do {
            try await decoder.append(bytes.prefix(1))
            XCTFail("Closed decoder must not reopen")
        } catch { }
    }

    func testTruncatedRealMP3FailsWithoutCompletedFileFallback() async throws {
        let bytes = try fixture().dropLast()
        let speech = OpenRouterProgressiveSpeech { _ in }
        do {
            for offset in stride(from: 0, to: bytes.count, by: 1024) {
                try await speech.append(Data(bytes[offset..<min(offset + 1024, bytes.count)]))
            }
            _ = try await speech.finish()
            XCTFail("A known incomplete frame must fail even if earlier PCM was accepted")
        } catch {
            XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse)
        }
        await speech.cancel()
    }

    func testReplacedConsumerThrowsCancellationRatherThanAcknowledgingPCM() async throws {
        let bytes = try fixture()
        let speech = OpenRouterProgressiveSpeech { _ in throw CancellationError() }
        do {
            for offset in stride(from: 0, to: bytes.count, by: 1024) {
                try await speech.append(bytes.subdata(in: offset..<min(offset + 1024, bytes.count)))
            }
            _ = try await speech.finish()
            XCTFail("A replaced playback owner must not return a successful result or file fallback")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await speech.cancel()
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "openrouter-tone-mp3", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func decode(
        _ bytes: Data, chunkSize: Int, pattern: [Int]? = nil
    ) async throws -> DecodedOutput {
        let decoder = IncrementalMP3Decoder()
        var result = Data()
        var chunks: [Data] = []
        var producedBeforeEOF = false
        do {
            var offset = 0
            var fragment = 0
            let sizes = pattern ?? [chunkSize]
            while offset < bytes.count {
                let end = min(offset + sizes[fragment % sizes.count], bytes.count)
                try await decoder.append(bytes.subdata(in: offset..<end))
                while let chunk = try await decoder.nextPCM() {
                    XCTAssertLessThanOrEqual(chunk.count, 4_800)
                    XCTAssertEqual(chunk.count % 2, 0)
                    if end < bytes.count { producedBeforeEOF = true }
                    result.append(chunk)
                    chunks.append(chunk)
                }
                offset = end
                fragment += 1
            }
            try await decoder.finishInput()
            while let chunk = try await decoder.nextPCM() {
                XCTAssertLessThanOrEqual(chunk.count, 4_800)
                result.append(chunk)
                chunks.append(chunk)
            }
            await decoder.close()
            return DecodedOutput(pcm: result, producedBeforeEOF: producedBeforeEOF, chunks: chunks)
        } catch {
            await decoder.close()
            throw error
        }
    }
}
#endif
