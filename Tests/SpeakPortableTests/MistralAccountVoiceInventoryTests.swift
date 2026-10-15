import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class MistralAccountVoiceInventoryTests: DeepgramSpeechStubTestCase {
    private let voiceID = "019b2bd7-96e7-7219-8c0b-45a73da50088"

    func testExplicitListing_BindsKeyAndUsesSharedRequestWithoutTextOrInventedPresets() async throws {
        respond(["items": [["id": voiceID, "name": "Synthetic voice"]]])
        let inventory = try await fetch()
        XCTAssertEqual(inventory.voices.map(\.id), [voiceID])
        XCTAssertEqual(inventory.voice(forID: "mistral/\(voiceID)")?.name, "Synthetic voice")
        XCTAssertNil(inventory.voice(forID: "foreign/\(voiceID)"))
        XCTAssertTrue(inventory.matchesCredential(" synthetic-list-key "))
        XCTAssertFalse(inventory.matchesCredential("another-key"))
        XCTAssertFalse(String(reflecting: inventory).contains("synthetic-list-key"))
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url?.host, MistralTTSAPI.voicesEndpoint.host)
        XCTAssertEqual(request.url?.path, MistralTTSAPI.voicesEndpoint.path)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems, [URLQueryItem(name: "limit", value: String(MistralTTSAPI.voicePageSize))])
    }

    func testPagination_UsesCanonicalOffsetsAndNeverAcceptsPartialListingAfterLaterFailure() async throws {
        let firstPage = (0..<MistralTTSAPI.voicePageSize).map { _ in
            ["id": UUID().uuidString, "name": "Synthetic paged voice"]
        }
        let firstData = try JSONSerialization.data(withJSONObject: ["items": firstPage])
        let lastData = try JSONSerialization.data(withJSONObject: ["items": [["id": voiceID, "name": "Last voice"]]])
        StubURLProtocol.handler = { request in
            let offset = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value
            return .respond(DeepgramSpeechFixture.response(request), offset == nil ? firstData : lastData)
        }
        let inventory = try await fetch()
        XCTAssertEqual(inventory.voices.count, MistralTTSAPI.voicePageSize + 1)
        XCTAssertEqual(inventory.voices.last?.id, voiceID)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        StubURLProtocol.handler = { request in
            if request.url?.query?.contains("offset=") == true {
                return .respond(DeepgramSpeechFixture.response(request, status: 503), Data("private body".utf8))
            }
            return .respond(DeepgramSpeechFixture.response(request), firstData)
        }
        do { _ = try await fetch(); XCTFail("A failed partial listing was admitted") } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .service(.mistral, 503))
        }
    }

    func testMalformedDuplicateOrOversizedListings_AreNotEmptyOrPartialSuccesses() async throws {
        let payloads: [[String: Any]] = [
            ["unknown": []],
            ["items": [["id": voiceID, "name": "Duplicate"], ["id": voiceID, "name": "Duplicate"]]],
            ["items": [["id": "invented-preset", "name": "Invalid"]]],
            ["items": [["id": voiceID, "name": ""]]],
            ["items": [["id": voiceID, "name": "Bad\nname"]]],
            ["items": [["id": voiceID, "name": "Valid", "gender": "bad\nvalue"]]]
        ]
        for payload in payloads {
            respond(payload)
            do { _ = try await fetch(); XCTFail("Invalid account listing admitted") } catch {
                XCTAssertEqual(error as? VoiceAccountDiscoveryError, .invalidInventory(.mistral))
            }
        }
        respond(["items": (0...MistralTTSAPI.voicePageSize).map { _ in
            ["id": UUID().uuidString, "name": "Oversized page"]
        }])
        do { _ = try await fetch(); XCTFail("An oversized page was admitted") } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .oversized(.mistral))
        }
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Length": String(MistralAccountVoiceInventory.maximumPageBytes + 1)
                ])), Data())
        }
        do { _ = try await fetch(); XCTFail("An oversized response was admitted") } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .oversized(.mistral))
        }
    }

    func testEmptyMissingCredentialFailureAndCancellation_AreExplicitlyDifferent() async throws {
        respond(["items": []])
        let inventory = try await fetch()
        XCTAssertTrue(inventory.voices.isEmpty)
        let count = StubURLProtocol.recordedRequests.count
        do { _ = try await MistralAccountVoiceInventory.fetch(session: session) { " " }
            XCTFail("Missing key admitted") } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .missingCredential(.mistral))
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        for status in [401, 403, 429, 503] {
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status), Data("private body".utf8))
            }
            do { _ = try await fetch(); XCTFail("Service failure admitted") } catch {
                XCTAssertEqual(error as? VoiceAccountDiscoveryError, .service(.mistral, status))
                XCTAssertFalse(error.localizedDescription.contains("private body"))
            }
        }
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do { _ = try await fetch(); XCTFail("Cancellation admitted") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        for (code, expected) in [
            (URLError.Code.timedOut, VoiceAccountDiscoveryError.timedOut(.mistral)),
            (.cannotConnectToHost, .transport(.mistral))
        ] {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            do { _ = try await fetch(); XCTFail("A transport failure was admitted") } catch {
                XCTAssertEqual(error as? VoiceAccountDiscoveryError, expected)
            }
        }
    }

    func testDuplicateAcrossPagesIncludingUUIDCasing_AndTotalInventoryBoundsRejectWholeListing() async throws {
        let entries = (0..<MistralTTSAPI.voicePageSize).map { index in
            ["id": index == 0 ? voiceID : UUID().uuidString, "name": "Synthetic voice"]
        }
        let first = try JSONSerialization.data(withJSONObject: ["items": entries])
        let duplicate = try JSONSerialization.data(withJSONObject: [
            "items": [["id": voiceID.uppercased(), "name": "Restated UUID"]]
        ])
        StubURLProtocol.handler = { request in
            .respond(DeepgramSpeechFixture.response(request), request.url?.query?.contains("offset=") == true
                ? duplicate : first)
        }
        do { _ = try await fetch(); XCTFail("A duplicate across pages was admitted") } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .invalidInventory(.mistral))
        }
        StubURLProtocol.handler = { request in
            let page = (0..<MistralTTSAPI.voicePageSize).map { _ in
                ["id": UUID().uuidString, "name": "Synthetic bounded voice"]
            }
            return .respond(DeepgramSpeechFixture.response(request),
                            try JSONSerialization.data(withJSONObject: ["items": page]))
        }
        do { _ = try await fetch(); XCTFail("An oversized total listing was admitted") } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .oversized(.mistral))
        }
    }

    func testCapturedDiscoveryContext_IsImmutableAndWrongProviderRefusesBeforeKeyOrTransport() async throws {
        respond(["items": [["id": voiceID, "name": "Synthetic voice"]]])
        let context = VoiceAccountCredentialContext(provider: .mistral, sessionID: UUID(), epoch: UUID())
        let inventory = try await MistralAccountVoiceInventory.fetch(session: session, context: context) {
            "synthetic-list-key"
        }
        XCTAssertEqual(inventory.context, context)
        let before = StubURLProtocol.recordedRequests.count
        do {
            _ = try await VoiceAccountInventory.fetch(provider: .mistral, session: session,
                context: .init(provider: .xai, sessionID: context.sessionID, epoch: context.epoch)) {
                    XCTFail("A foreign provider context read a key")
                    return "synthetic-list-key"
                }
            XCTFail("A foreign provider discovery context was admitted")
        } catch {
            XCTAssertEqual(error as? VoiceAccountDiscoveryError, .invalidInventory(.mistral))
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, before)
    }

    private func respond(_ payload: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
        } catch { XCTFail("Invalid synthetic fixture: \(error)") }
    }

    private func fetch() async throws -> MistralAccountVoiceInventory {
        try await .fetch(session: session) { "synthetic-list-key" }
    }
}
