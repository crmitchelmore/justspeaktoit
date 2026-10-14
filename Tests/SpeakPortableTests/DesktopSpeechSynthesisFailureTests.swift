import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopSpeechSynthesisFailureTests: DeepgramSpeechStubTestCase {
    func testOversizedSSML_RefusesBeforeReadingCredentialOrSendingRequest() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "x", count: DesktopSpeechSynthesis.maximumSSMLBytes + 1))
        let probe = CredentialProbe()
        do {
            _ = try await synthesize(source, options: VoiceSynthesisOptions(useSSML: true)) {
                try await probe.supply()
            }
            XCTFail("Oversized SSML was admitted")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .ssmlTooLarge) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testInvalidAndSilentAudio_NeverProduceCompletedOutput() async throws {
        for body in [Data(), Data("synthetic non-audio".utf8),
                     DeepgramSpeechFixture.canonicalWAV(pcm: Data(repeating: 0, count: 200))] {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), body) }
            do {
                _ = try await synthesize(source)
                XCTFail("Invalid audio was published")
            } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        }
    }

    func testProviderStatusAndTransportFailures_DoNotExposeResponseOrCredential() async throws {
        StubURLProtocol.handler = {
            .respond(DeepgramSpeechFixture.response($0, status: 401), Data("synthetic-private-body".utf8))
        }
        do {
            _ = try await synthesize(source)
            XCTFail("Unauthorized synthesis succeeded")
        } catch {
            XCTAssertTrue(error is AzureSpeechError)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-body"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
        }
        StubURLProtocol.handler = { _ in .fail(URLError(.notConnectedToInternet)) }
        do {
            _ = try await synthesize(source)
            XCTFail("Transport failure succeeded")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .transportFailure) }
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do {
            _ = try await synthesize(source)
            XCTFail("Cancellation succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSecondSegmentFailure_NeverReturnsPartialCompletedAudio() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        let count = FailureRequestCounter()
        StubURLProtocol.handler = { request in
            let status = count.nextStatus()
            return .respond(DeepgramSpeechFixture.response(request, status: status), audio)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "Synthetic sentence. ", count: 180))
        do {
            _ = try await synthesize(source)
            XCTFail("Partial audio was accepted as complete")
        } catch { XCTAssertTrue(error is AzureSpeechError) }
        XCTAssertEqual(count.count, 2)
    }

    private var source: VoiceOutputSourceSnapshot {
        get throws { try .init(source: .typedText, text: "Synthetic speech.") }
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot, options: VoiceSynthesisOptions? = nil,
        credential: @Sendable () async throws -> String = { "synthetic-key:eastus" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]),
            options: options ?? VoiceSynthesisOptions(), credential: credential
        )
    }
}

private final class FailureRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func nextStatus() -> Int { lock.withLock { calls += 1; return calls == 1 ? 200 : 503 } }
}
