import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class XAIAccountVoiceInventoryTests: DeepgramSpeechStubTestCase {
    func testListing_BindsCredentialAndPreservesAccountIdentifiersWithoutCopyingPresets() async throws {
        respond(#"{"voices":[{"voice_id":"eve"},{"voice_id":"ara"},"# +
            #"{"voice_id":"Account-A","name":"Synthetic voice"}]}"#)
        let inventory = try await fetch()
        XCTAssertEqual(inventory.voices.map(\.id), ["Account-A"])
        XCTAssertTrue(inventory.matchesCredential(" synthetic-key "))
        XCTAssertFalse(inventory.matchesCredential("different-key"))
        XCTAssertFalse(String(reflecting: inventory).contains("synthetic-key"))
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url, XAITTSAPI.voicesEndpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let voice = try DesktopSpeechVoice.resolved(modelID: "xai", voiceID: "xai/Account-A",
                                                    xaiInventory: inventory)
        XCTAssertEqual(voice.id, "xai/Account-A")
        XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: "xai", voiceID: "xai/account-a",
                                                            xaiInventory: inventory))
        XCTAssertNoThrow(try DesktopSpeechSelection(voice: voice, options: VoiceSynthesisOptions(),
                                                    xaiInventory: inventory))
        XCTAssertThrowsError(try DesktopSpeechSelection(voice: voice, options: VoiceSynthesisOptions()))
    }

    func testMalformedDuplicateOrOversizedListing_IsNeverAccepted() async throws {
        for body in [
            #"{"voices":[{"voice_id":"same"},{"voice_id":"same"}]}"#,
            #"{"voices":[{"voice_id":" invalid"}]}"#,
            #"{"voices":[{"voice_id":"bad\nid"}]}"#,
            #"{"voices":[{"voice_id":"xai/already-prefixed"}]}"#,
            #"{"voices":[{"voice_id":"valid","name":""}]}"#,
            #"{"voices":[{"voice_id":"valid","name":"bad\nname"}]}"#,
            #"{"voices":[{"name":"missing id"}]}"#, #"{"not_voices":[]}"#
        ] {
            respond(body)
            do { _ = try await fetch(); XCTFail("Invalid listing admitted") } catch {
                XCTAssertEqual(error as? XAIAccountVoiceDiscoveryError, .invalidInventory)
            }
        }
        let entries = (0...XAIAccountVoiceInventory.maximumVoices).map {
            ["voice_id": "synthetic-\($0)"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["voices": entries])
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
        do { _ = try await fetch(); XCTFail("Excess entries admitted") } catch {
            XCTAssertEqual(error as? XAIAccountVoiceDiscoveryError, .oversized)
        }
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap($0.url), statusCode: 200,
                httpVersion: nil, headerFields: [
                    "Content-Length": String(XAIAccountVoiceInventory.maximumResponseBytes + 1)
                ])), Data())
        }
        do { _ = try await fetch(); XCTFail("Excess response admitted") } catch {
            XCTAssertEqual(error as? XAIAccountVoiceDiscoveryError, .oversized)
        }
    }

    func testEmptyAndFailedListings_ExplicitlyDistinguishSuccessFailureAndCancellation() async throws {
        respond(#"{"voices":[]}"#)
        let empty = try await fetch()
        XCTAssertTrue(empty.voices.isEmpty)
        for status in [401, 403, 429, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private body".utf8))
            }
            do { _ = try await fetch(); XCTFail("Service failure admitted") } catch {
                XCTAssertEqual(error as? XAIAccountVoiceDiscoveryError, .service(status))
                XCTAssertFalse(error.localizedDescription.contains("private body"))
            }
        }
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do { _ = try await fetch(); XCTFail("Cancelled listing admitted") } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAccountSynthesis_UsesProofAndActualCredentialBeforeAnyRequestOrUsage() async throws {
        respond(#"{"voices":[{"voice_id":"Account-A","name":"Synthetic voice"}]}"#)
        let inventory = try await fetch()
        let voice = try XCTUnwrap(inventory.desktopVoices.first)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic account input.")
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let before = StubURLProtocol.recordedRequests.count
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: voice, options: VoiceSynthesisOptions(), xaiInventory: inventory,
                    credential: { "different-key" })
            }
            XCTFail("Changed credential admitted synthesis")
        } catch { XCTAssertEqual(error as? XAIAccountVoiceDiscoveryError, .credentialChanged) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, before)
        XCTAssertTrue(capture.records.isEmpty)
        let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: VoiceSynthesisOptions(), xaiInventory: inventory,
                credential: { "synthetic-key" })
        }
        XCTAssertEqual(wav, audio)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
        XCTAssertEqual(body["voice_id"] as? String, XAITTSCatalog.resolvedAPIVoiceID(forVoiceID: voice.id))
        XCTAssertEqual(capture.records.first?.voiceID, voice.id)
        XCTAssertNil(capture.records.first?.historyRecordID)
        XCTAssertNotNil(capture.records.first?.estimatedCostUSD)
    }

    private func respond(_ body: String) {
        let data = Data(body.utf8)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
    }

    private func fetch() async throws -> XAIAccountVoiceInventory {
        try await .fetch(session: session, credential: { "synthetic-key" })
    }
}
