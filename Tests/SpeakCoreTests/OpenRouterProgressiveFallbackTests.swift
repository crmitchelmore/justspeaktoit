#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation
import XCTest

@testable import SpeakCore

final class OpenRouterProgressiveFallbackTests: XCTestCase {
    func testUnavailableNativeSetupKeepsValidatingSameResponseAndRequiresCompletedFileWithoutPCM() async throws {
        let recorder = FallbackConsumerRecorder()
        let speech = unavailableSpeech(recorder: recorder)
        try await Self.append(try fixture(), to: speech)
        let result = try await speech.finish()
        XCTAssertFalse(result.pcmProduced)
        XCTAssertTrue(result.completedFileRequired)
        let chunks = await recorder.calls
        XCTAssertEqual(chunks, 0)
    }

    func testKnownTruncationAndMalformedHeaderStillFailWhenNativeSetupIsUnavailable() async throws {
        let complete = try fixture()
        let inputs = [Data(complete.dropLast()), Data([255, 251, 116, 0])]
        for bytes in inputs {
            let recorder = FallbackConsumerRecorder()
            let speech = unavailableSpeech(recorder: recorder)
            do {
                try await Self.append(bytes, to: speech)
                _ = try await speech.finish()
                XCTFail("Fallback must not hide known incomplete MP3 frames")
            } catch { XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse) }
            await speech.cancel()
            let chunks = await recorder.calls
            XCTAssertEqual(chunks, 0)
        }
        let speech = unavailableSpeech(recorder: FallbackConsumerRecorder())
        do {
            try await speech.append(Data([0, 0, 0, 0]))
            XCTFail("Malformed framing must fail before native setup or fallback")
        } catch { XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse) }
        await speech.cancel()
    }

    func testCancellationDuringFallbackStillRefusesCompletedFileSuccess() async throws {
        let bytes = try fixture()
        let speech = unavailableSpeech(recorder: FallbackConsumerRecorder())
        // First append actually enters the native-unavailable fallback branch.
        try await speech.append(Data(bytes.prefix(1024)))
        let entered = expectation(description: "Owned task reached cancellation gate")
        let gate = FallbackCancellationGate()
        let task = Task {
            entered.fulfill()
            await gate.wait()
            try await Self.append(Data(bytes.dropFirst(1024)), to: speech)
            return try await speech.finish()
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a completed-file result")
        } catch { XCTAssertTrue(error is CancellationError) }
        await speech.cancel()
    }

    func testUnavailableTypedErrorAfterFirstAcceptedChunkCannotReopenFallback() async throws {
        let recorder = FallbackConsumerRecorder()
        let speech = OpenRouterProgressiveSpeech { _ in
            let call = await recorder.record()
            // Defensive internal-error injection after real native output and
            // first acceptance; this is not a native setup-after-ready repro.
            if call > 1 { throw IncrementalMP3Decoder.Failure.unavailable }
        }
        do {
            try await Self.append(try fixture(), to: speech)
            _ = try await speech.finish()
            XCTFail("Once scheduling was acknowledged, no error may request replay")
        } catch { XCTAssertEqual(error as? OpenRouterAudioError, .invalidResponse) }
        let calls = await recorder.calls
        XCTAssertEqual(calls, 2)
        await speech.cancel()
    }

    private func unavailableSpeech(recorder: FallbackConsumerRecorder) -> OpenRouterProgressiveSpeech {
        let decoder = IncrementalMP3Decoder(nativeFactory: { throw IncrementalMP3Decoder.Failure.unavailable })
        return OpenRouterProgressiveSpeech(decoder: decoder) { _ in _ = await recorder.record() }
    }

    private static func append(_ bytes: Data, to speech: OpenRouterProgressiveSpeech) async throws {
        for start in stride(from: 0, to: bytes.count, by: 1024) {
            try await speech.append(bytes.subdata(in: start..<min(start + 1024, bytes.count)))
        }
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "openrouter-tone-mp3", withExtension: "mp3", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }
}

private actor FallbackCancellationGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private actor FallbackConsumerRecorder {
    private(set) var calls = 0

    func record() -> Int { calls += 1; return calls }
}
#endif
