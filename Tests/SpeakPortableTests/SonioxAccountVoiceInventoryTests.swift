import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class SonioxAccountVoiceInventoryTests: DeepgramSpeechStubTestCase {
    func testReadyOnlyClones_UseExactContextRegionAndCredentialWithoutDefaultVoiceSubstitution() async throws {
        let context = VoiceAccountCredentialContext(provider: .soniox, sessionID: UUID(), epoch: UUID())
        let data = try page([entry("ready", status: "ready"), entry("pending", status: "not_computed"),
                             entry("failed", status: "failed")])
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
        let inventory = try await VoiceAccountInventory.fetch(
            provider: .soniox, session: session, context: context, sonioxRegion: .europe) { "synthetic-key" }
        XCTAssertEqual(inventory.soniox?.voices.count, 3)
        XCTAssertEqual(inventory.soniox?.context, context)
        XCTAssertEqual(inventory.soniox?.region, .europe)
        XCTAssertEqual(inventory.desktopVoices.map(\.id), ["soniox/ready"])
        XCTAssertTrue(inventory.matchesCredential(" synthetic-key "))
        XCTAssertFalse(String(reflecting: inventory).contains("synthetic-key"))
        XCTAssertFalse(String(reflecting: try XCTUnwrap(inventory.soniox)).contains("synthetic-key"))
        let ready = try XCTUnwrap(inventory.desktopVoices.first)
        XCTAssertEqual(try DesktopSpeechVoice.resolved(
            modelID: "tts-rt-v1", voiceID: ready.id, accountInventory: inventory), ready)
        for identifier in ["soniox/pending", "soniox/failed", "soniox/deleted"] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(
                modelID: "tts-rt-v2", voiceID: identifier, accountInventory: inventory))
        }
        XCTAssertThrowsError(try DesktopSpeechSelection(
            voice: ready, options: VoiceSynthesisOptions(), accountInventory: inventory, sonioxRegion: .japan))
        let before = StubURLProtocol.recordedRequests.count
        do {
            _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                .init(source: .typedText, text: "Synthetic clone."), voice: ready, options: VoiceSynthesisOptions(),
                accountInventory: inventory, sonioxRegion: .europe, credential: { "changed-key" })
            XCTFail("Changed key admitted stale clone")
        } catch { XCTAssertEqual(error as? VoiceAccountDiscoveryError, .credentialChanged(.soniox)) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, before)
    }

    func testPagination_FollowsCanonicalCursorOnlyOnCapturedRegionalHost() async throws {
        let first = try page([entry("one")], cursor: "next + /")
        let last = try page([entry("two")])
        StubURLProtocol.handler = { request in
            let cursor = URLComponents(url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            return .respond(DeepgramSpeechFixture.response(request), cursor == nil ? first : last)
        }
        let inventory = try await SonioxAccountVoiceInventory.fetch(session: session, region: .japan) {
            "synthetic-key"
        }
        XCTAssertEqual(inventory.desktopVoices.map(\.id), ["soniox/one", "soniox/two"])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        XCTAssertTrue(StubURLProtocol.recordedRequests.allSatisfy { $0.url?.host == SonioxTTSRegion.japan.apiHost })
    }

    func testRepeatedCursorDuplicateIDsAndPresetCollisions_RejectWholeListing() async throws {
        let invalid = try [
            page([entry("one")], cursor: "same"),
            page([entry("one"), entry("ONE")]),
            page([entry(SonioxTTSCatalog.defaultVoiceID)]),
            page([entry("bad/id")])
        ]
        for data in invalid {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
            do {
                _ = try await SonioxAccountVoiceInventory.fetch(session: session, region: .europe) { "synthetic-key" }
                XCTFail("Invalid inventory admitted")
            } catch { XCTAssertEqual(error as? VoiceAccountDiscoveryError, .invalidInventory(.soniox)) }
        }
    }

    func testInventoryBoundsAndRegionalFailure_NeverAcceptPartialVoicesOrTryUS() async throws {
        let data = try page((0...SonioxAccountVoiceInventory.maximumVoices).map { entry("voice-\($0)") })
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
        do {
            _ = try await SonioxAccountVoiceInventory.fetch(session: session, region: .europe) { "synthetic-key" }
            XCTFail("Oversized inventory admitted")
        } catch { XCTAssertEqual(error as? VoiceAccountDiscoveryError, .oversized(.soniox)) }
        StubURLProtocol.reset()
        StubURLProtocol.handler = {
            .respond(DeepgramSpeechFixture.response($0, status: 401), Data("synthetic-sensitive-body".utf8))
        }
        do {
            _ = try await SonioxAccountVoiceInventory.fetch(session: session, region: .japan) { "synthetic-key" }
            XCTFail("Regional authentication failure admitted")
        } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .service(.soniox, 401))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-body"))
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.first?.url?.host, SonioxTTSRegion.japan.apiHost)
    }

    func testPageByteBoundsAndCancellation_RejectWithoutAcceptingInventory() async throws {
        let maximum = SonioxAccountVoiceInventory.maximumPageBytes
        StubURLProtocol.handler = {
            .respond(DeepgramSpeechFixture.response($0, headers: ["Content-Length": "\(maximum + 1)"]), Data())
        }
        do {
            _ = try await SonioxAccountVoiceInventory.fetch(session: session, region: .europe) { "synthetic-key" }
            XCTFail("Over-limit voice page accepted")
        } catch { XCTAssertEqual(error as? VoiceAccountDiscoveryError, .oversized(.soniox)) }
        StubURLProtocol.reset()
        let entered = expectation(description: "synthetic regional listing entered")
        StubURLProtocol.onStartLoading = { entered.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let session = try XCTUnwrap(session)
        let work = Task {
            try await SonioxAccountVoiceInventory.fetch(session: session, region: .japan) { "synthetic-key" }
        }
        await fulfillment(of: [entered], timeout: 3)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled voice listing accepted") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private func entry(_ id: String, status: String = "ready") -> [String: Any] {
        ["id": id, "name": "Synthetic \(id)", "models": [
            ["model": SonioxTTSCatalog.defaultModel.rawValue, "status": status]
        ]]
    }

    private func page(_ voices: [[String: Any]], cursor: String? = nil) throws -> Data {
        var page: [String: Any] = ["voices": voices]
        if let cursor { page["next_page_cursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: page)
    }
}
