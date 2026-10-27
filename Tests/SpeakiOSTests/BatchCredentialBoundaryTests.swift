#if os(iOS)
import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakiOSLib

@MainActor
final class BatchCredentialBoundaryTests: XCTestCase {
    func testRestoredManualModel_RejectsResolvedElevenLabsKeyWithoutRequest() async throws {
        let suite = "BatchCredentialBoundaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("elevenlabs/scribe_v2", forKey: "batchTranscriptionModel")
        let storage = SecureStorage(
            configuration: .init(service: suite), permissionsChecker: BoundaryDeniedKeychainAccess()
        )
        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false, credentialStorage: storage)
        settings.elevenLabsAPIKey = "synthetic-elevenlabs-only"
        settings.openRouterAPIKey = "synthetic-openrouter-only"
        await settings.awaitPendingSecretWrites()
        XCTAssertEqual(settings.batchTranscriptionModel, "elevenlabs/scribe_v2")
        XCTAssertEqual(settings.batchAPIKey, "synthetic-elevenlabs-only")

        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            XCTFail("A restored unsupported direct-provider key must never be sent")
            return .fail(URLError(.userAuthenticationRequired))
        }
        await assertUnsupported(model: settings.batchTranscriptionModel, key: settings.batchAPIKey, session: session)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testUnsupportedDirectAndLocalFallbacks_RefuseBeforeSuppliedKeyValidationOrAudioRead() async {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            XCTFail("An unsupported fallback must not start any request")
            return .fail(URLError(.userAuthenticationRequired))
        }
        for model in [
            "elevenlabs/scribe_v2", " \nelevenlabs/scribe_v2\t ", "xai/grok-voice",
            "cartesia/unknown", "deepgram/unknown", "speechmatics/batch",
            "local/whisper", "apple/unknown", "system/unknown"
        ] {
            // Both an empty key and a nonexistent file would fail differently
            // if credential access or audio preparation ran before the guard.
            await assertUnsupported(model: model, key: "", session: session)
            await assertUnsupported(model: model, key: "synthetic-direct-key", session: session)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCustomAndExplicitOpenRouterModels_PreserveHostAndCredential() async throws {
        for model in [
            "example/custom-audio", "example/organization/nested-model",
            "openrouter/transcription/elevenlabs/scribe_v2",
            "openrouter/transcription/example/organization/nested-model"
        ] {
            try await assertRequest(model: model, host: "openrouter.ai", key: "synthetic-openrouter-only")
        }
    }

    func testImplementedDirectAndCatalogOpenRouterRoutes_PreserveCredentialHost() async throws {
        try await assertRequest(
            model: GeminiTranscribeModels.batchCatalogID,
            host: "generativelanguage.googleapis.com", key: "synthetic-google-only", header: "x-goog-api-key"
        )
        try await assertRequest(
            model: "openai/gpt-transcribe", host: "api.openai.com", key: "synthetic-openai-only"
        )
        try await assertRequest(
            model: "google/gemini-3.1-flash-lite", host: "openrouter.ai", key: "synthetic-openrouter-only"
        )
    }

    private func assertUnsupported(model: String, key: String, session: URLSession) async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            _ = try await IOSBatchTranscriber.transcribeFile(
                at: missing, model: model, apiKey: key, language: nil, session: session
            )
            XCTFail("An unsupported credential owner must refuse the file route")
        } catch let IOSBatchTranscriptionError.jobFailed(service, message) {
            XCTAssertEqual(service, "Batch transcription")
            XCTAssertEqual(message, "This batch model is not supported on this device.")
        } catch {
            XCTFail("The credential boundary must fail before missing-key or audio-file validation")
        }
    }

    private func assertRequest(
        model: String, host: String, key: String, header: String = "Authorization"
    ) async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        let received = expectation(description: "Exact credential destination: " + model)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, host)
            XCTAssertEqual(request.value(forHTTPHeaderField: header), header == "Authorization" ? "Bearer " + key : key)
            if header != "Authorization" { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
            if host == "openrouter.ai" {
                let wrapped = OpenRouterTranscriptionSelection.modelID(from: model)
                let path = wrapped == nil ? "/api/v1/chat/completions" : "/api/v1/audio/transcriptions"
                XCTAssertEqual(request.url?.path, path)
                let body = StubURLProtocol.body(of: request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(payload?["model"] as? String, wrapped ?? model)
                XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            }
            received.fulfill()
            return .fail(URLError(.userAuthenticationRequired))
        }
        do {
            _ = try await IOSBatchTranscriber.transcribeFile(
                at: audio, model: " \n" + model + "\t ", apiKey: key, language: nil, session: session
            )
            XCTFail("The sentinel transport must reject the request")
        } catch {
            // The expectation requires the actual host/header boundary: a
            // local validation failure cannot make the positive case pass.
        }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }
}

/// This mapping fixture must not read or write even its synthetic vault.
private struct BoundaryDeniedKeychainAccess: KeychainPermissionsChecking {
    func ensureKeychainAccess(forService: String) async -> Bool { false }
}
#endif
