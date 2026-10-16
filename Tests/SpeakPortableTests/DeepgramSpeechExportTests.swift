import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DeepgramSpeechExportTests: DeepgramSpeechStubTestCase {
    func testLongSource_CombinesPCMIntoOneExactWAVAndReadsCredentialOnce() async throws {
        let streamed = DeepgramSpeechFixture.streamedWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), streamed) }
        let text = String(repeating: "Synthetic speech sentence. ", count: 180)
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: text)
        let voice = DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: nil).voice
        let credential = CredentialProbe()
        let wav = try await DeepgramSpeechExport(session: session).synthesize(snapshot, voice: voice) {
            try await credential.supply()
        }
        let count = SpeechTextSegmenter.segments(text).count
        XCTAssertGreaterThan(count, 1)
        let combined = Data((0..<count).flatMap { _ in Array(pcm) })
        XCTAssertEqual(wav, DeepgramSpeechFixture.canonicalWAV(pcm: combined))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        XCTAssertEqual(credential.count, 1)
        XCTAssertEqual(try DeepgramSpeechWAV.canonical(wav, sampleRate: 24_000).frameCount, 4_800 * count)
    }

    func testFailedSegment_NeverReturnsPartialAudio() async throws {
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0, status: 401), Data()) }
        let snapshot = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic snapshot")
        do {
            _ = try await DeepgramSpeechExport(session: session).synthesize(
                snapshot, voice: DeepgramSpeechCatalog.voices[0], credential: { "fixture-key" }
            )
            XCTFail("Failure returned audio")
        } catch { XCTAssertEqual(error as? DeepgramSpeechError, .unauthorized(statusCode: 401)) }
    }

    func testCancelledCredential_NeverStartsProviderExchange() async throws {
        let credential = CredentialProbe(holdUntilReleased: true)
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic text")
        let exporter = DeepgramSpeechExport(session: session)
        let task = Task { try await exporter.synthesize(snapshot, voice: DeepgramSpeechCatalog.voices[0]) {
            try await credential.supply()
        } }
        for _ in 0..<500 where credential.count < 1 { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel(); credential.release()
        do { _ = try await task.value; XCTFail("Cancelled export returned audio") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }
}
