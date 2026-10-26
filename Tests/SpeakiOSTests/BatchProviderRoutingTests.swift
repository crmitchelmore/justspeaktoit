#if os(iOS)
import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakiOSLib

@MainActor
final class BatchProviderRoutingTests: XCTestCase {
    func testExistingBatchRoutePrecedenceAndFallback() {
        let cases: [(String, IOSBatchTranscriptionRoute)] = [
            (AppleLocalModels.speechTranscriberModelID, .appleSpeechAnalyzer),
            ("openai/whisper-1", .openAI),
            (CartesiaBatchClient.catalogID, .cartesia),
            (GladiaBatchClient.catalogID, .gladia),
            (AzureTranscriptionModels.mai2, .azure),
            ("alibaba/unknown", .alibaba),
            (MetaMuseVoiceTranscribe.batchCatalogID, .metaMuse),
            (GeminiTranscribeModels.batchCatalogID, .gemini),
            (XAISpeechToText.batchCatalogID, .xai),
            (FileSpeechProvider.smallest.modelID, .fileSpeech(.smallest)),
            ("google/gemini-3.1-flash-lite", .openRouter),
            ("openai/gpt-audio", .openRouter),
            ("openrouter/transcription/openai/gpt-transcribe", .openRouter),
            ("elevenlabs/scribe_v2", .openRouter),
            ("OpenAI/whisper-1", .openRouter),
            ("/alibaba/unknown", .openRouter),
            ("alibaba", .openRouter),
            ("unknown/model", .openRouter),
            ("", .openRouter)
        ]
        for (model, expected) in cases {
            XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: model), expected, model)
            XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: " \n" + model + "\t"), expected, model)
        }
    }

    func testEverySelectableBatchModelKeepsItsTransportAndCredentialOwner() throws {
        for model in AppSettings.supportedBatchModels {
            let route = try XCTUnwrap(BatchTranscriptionRouting.route(for: model.id, platform: .iOS))
            let requirement = ModelCredentialResolver.requirement(for: model.id, purpose: .batchTranscription)
            switch requirement {
            case .notRequired:
                XCTAssertEqual(route.transport, .appleLocal, model.id)
                XCTAssertNil(route.apiKeyIdentifier, model.id)
            case .apiKey(let identifier, _):
                XCTAssertEqual(route.apiKeyIdentifier, identifier, model.id)
            }
            let backend = IOSBatchTranscriptionRoute.route(for: model.id)
            XCTAssertEqual(Self.providerID(for: backend), route.providerID, model.id)
        }
    }

    // Each existing native backend has its own expected transport owner.
    // swiftlint:disable:next cyclomatic_complexity
    private static func providerID(for route: IOSBatchTranscriptionRoute) -> String {
        switch route {
        case .appleSpeechAnalyzer: return "apple"
        case .openAI: return "openai"
        case .metaMuse: return "meta"
        case .azure: return "azure"
        case .alibaba: return "alibaba"
        case .cartesia: return "cartesia"
        case .gladia: return "gladia"
        case .gemini: return "google"
        case .xai: return "xai"
        case .fileSpeech(let provider): return provider.rawValue
        case .openRouter: return "openrouter"
        }
    }

    func testPaddedModelsSendCredentialsOnlyToTheirProvider() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { StubURLProtocol.reset() }

        let cases = [
            (GeminiTranscribeModels.batchCatalogID, "generativelanguage.googleapis.com", "google-test-key"),
            ("google/gemini-3.1-flash-lite", "openrouter.ai", "openrouter-test-key"),
            ("openrouter/transcription/openai/gpt-transcribe", "openrouter.ai", "openrouter-test-key")
        ]
        for (model, host, key) in cases {
            let received = expectation(description: "Request reached " + host)
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, host)
                if host == "generativelanguage.googleapis.com" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
                }
                received.fulfill()
                return .fail(URLError(.userAuthenticationRequired))
            }
            do {
                _ = try await IOSBatchTranscriber.transcribeFile(
                    at: audioURL, model: " \n" + model + "\t ", apiKey: key, language: nil, session: session
                )
                XCTFail("The stub rejects the request after checking its destination")
            } catch {
                // The assertions above must run: local validation failure alone
                // must not make this credential-routing regression test pass.
            }
            await fulfillment(of: [received], timeout: 2)
        }
    }

    /// The Cartesia route reports failures in the shared vocabulary the app and
    /// keyboard render (provider name + status), and a silent recording is an
    /// error rather than an empty insert, matching the OpenAI/OpenRouter routes.
    func testCartesiaRouteMapsErrorsAndEmptyTranscriptsLikeSiblingRoutes() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2, 3]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { StubURLProtocol.reset() }

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.cartesia.ai")
            return .status(401, Data(#"{"error":"bad key"}"#.utf8), url: request.url!)
        }
        do {
            _ = try await IOSBatchTranscriber.transcribeFile(
                at: audioURL, model: CartesiaBatchClient.catalogID, apiKey: "k", language: nil, session: session
            )
            XCTFail("A rejected key must surface as an error")
        } catch let IOSBatchTranscriptionError.httpError(service, status, _) {
            XCTAssertEqual(service, "Cartesia")
            XCTAssertEqual(status, 401)
        }

        StubURLProtocol.handler = { request in
            .status(
                200,
                Data(#"{"type":"transcript","text":"  ","language":"en","duration":0.5,"words":[]}"#.utf8),
                url: request.url!
            )
        }
        do {
            _ = try await IOSBatchTranscriber.transcribeFile(
                at: audioURL, model: CartesiaBatchClient.catalogID, apiKey: "k", language: nil, session: session
            )
            XCTFail("A blank transcript must not be inserted silently")
        } catch IOSBatchTranscriptionError.emptyTranscript {
            // Expected.
        }
    }
}

#endif
