import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class NativePCM16WAVReaderTests: XCTestCase {
    func testHeaderProbeAcceptsOnlyCompleteCanonicalAudio() throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let canonical = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        try canonical.write(to: audio)
        XCTAssertEqual(try NativePCM16WAVReader.canonicalDuration(at: audio), 2.0 / 16_000, accuracy: 1e-9)
        let stereo = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000, channels: 2))
        let empty = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(), sampleRate: 16_000))
        for invalid in [Data(canonical.dropLast()), stereo, empty, Data()] {
            try invalid.write(to: audio)
            XCTAssertThrowsError(try NativePCM16WAVReader.canonicalDuration(at: audio))
        }
    }

    func testNativeRecordingPassesThroughByteForByteWithMeasuredDuration() throws {
        let pcm = Data([0xFF, 0x7F, 0, 0x80, 0, 0])
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000))
        let prepared = try prepare(bytes)
        XCTAssertEqual(prepared.data, bytes)
        XCTAssertEqual(prepared.duration, 3.0 / 16_000, accuracy: 0.000_000_001)
    }

    func testOtherRatesChannelsAndBitDepthsRequireConversion() throws {
        for (rate, channels, bits) in [(48_000, 1, 16), (16_000, 2, 16), (16_000, 1, 32)] {
            let wav = try XCTUnwrap(PCMWaveWriter.wavData(
                pcm: Data(repeating: 1, count: 8), sampleRate: rate, channels: channels, bitsPerSample: bits
            ))
            XCTAssertThrowsError(try prepare(wav)) { error in
                XCTAssertEqual(error as? NativePCM16WAVReader.PreparationError, .unsupportedFormat)
            }
        }
        XCTAssertThrowsError(try prepare(Data(repeating: 1, count: 100))) { error in
            XCTAssertEqual(error as? NativePCM16WAVReader.PreparationError, .unsupportedFormat)
        }
    }

    func testTruncationLengthMismatchOddFramesAndOverflowHeadersAreRejected() throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        var wrongRIFF = wav
        wrongRIFF[4] = 1
        var wrongData = wav
        wrongData[40] = 2
        var overflow = wav
        overflow.replaceSubrange(4..<8, with: [255, 255, 255, 255])
        var oddFrame = wav
        oddFrame.removeLast()
        oddFrame[4] -= 1
        oddFrame[40] -= 1
        for bytes in [Data(wav.prefix(20)), Data(wav.dropLast()), wrongRIFF, wrongData, overflow, oddFrame] {
            XCTAssertThrowsError(try prepare(bytes)) { error in
                XCTAssertEqual(error as? NativePCM16WAVReader.PreparationError, .invalidContainer)
            }
        }
    }

    func testEmptyRecordingIsRejectedBeforeUpload() throws {
        let empty = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(), sampleRate: 16_000))
        XCTAssertThrowsError(try prepare(empty)) { error in
            XCTAssertEqual(error as? NativePCM16WAVReader.PreparationError, .emptyInput)
        }
    }

    func testExactDurationLimitIsAcceptedButByteLimitRemainsExclusive() throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0]), sampleRate: 16_000))
        XCTAssertNoThrow(try prepare(wav, maximumDuration: 1.0 / 16_000))
        XCTAssertThrowsError(try prepare(wav, maximumDuration: 0)) { error in
            XCTAssertEqual(error as? NativePCM16WAVReader.PreparationError, .limitExceeded)
        }
        XCTAssertThrowsError(try prepare(wav, maximumBytes: wav.count)) { error in
            XCTAssertEqual(error as? NativePCM16WAVReader.PreparationError, .limitExceeded)
        }
        XCTAssertNoThrow(try prepare(wav, maximumBytes: wav.count + 1))
    }

    func testCancellationIsCheckedBeforeReadingAnyFile() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NativePCM16WAVReader.prepare(
                at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                maximumDuration: 600, maximumBytes: 32 * 1_024 * 1_024
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before file access")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPreparedClientsRejectUnsupportedImportsWithoutNetworking() async throws {
        defer { StubURLProtocol.reset() }
        for bytes in [Data("malformed audio".utf8), try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data([1, 0, 2, 0]), sampleRate: 48_000
        ))] {
            let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try bytes.write(to: audio)
            defer { try? FileManager.default.removeItem(at: audio) }
            for azure in [false, true] {
                do {
                    _ = try await transcribe(audio, azure: azure)
                    XCTFail("Expected invalid or unsupported audio")
                } catch {
                    guard case MetaMuseError.invalidAudio = error else { return XCTFail("Unexpected error: \(error)") }
                }
                XCTAssertEqual(try Data(contentsOf: audio), bytes)
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testBothClientsRetainTheExistingTenMinutePreparationLimit() async throws {
        defer { StubURLProtocol.reset() }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data().write(to: audio)
        let output = try FileHandle(forWritingTo: audio)
        try output.truncate(atOffset: UInt64(44 + 601 * 32_000))
        try output.close()
        for azure in [false, true] {
            do {
                _ = try await transcribe(audio, azure: azure)
                XCTFail("Expected the existing 600-second limit")
            } catch { XCTAssertEqual(error as? MetaMuseError, .requestTooLarge) }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private func transcribe(_ audio: URL, azure: Bool) async throws -> TranscriptionResult {
        let session = StubURLProtocol.makeSession()
        if azure {
            return try await AzureBatchTranscriptionClient(session: session).transcribeFile(
                at: audio, credentials: "fixture", endpoint: "", model: AzureTranscriptionModels.fast, language: nil
            )
        }
        return try await MetaMuseBatchClient(session: session)
            .transcribeFile(at: audio, apiKey: "fixture", language: nil)
    }

    private func prepare(
        _ data: Data, maximumDuration: TimeInterval = 600, maximumBytes: Int = 32 * 1_024 * 1_024
    ) throws -> NativePCM16WAVReader.PreparedAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NativePCM16WAVReader.prepare(at: url, maximumDuration: maximumDuration, maximumBytes: maximumBytes)
    }
}
