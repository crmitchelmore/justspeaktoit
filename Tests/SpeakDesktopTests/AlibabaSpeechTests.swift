import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

final class AlibabaSpeechTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testConfiguration_RoundTripsTheKeyRegionAndWorkspaceTogether() throws {
        for region in AlibabaSpeechConfiguration.Region.allCases {
            let config = try AlibabaSpeechConfiguration(region: region, workspace: "llm-example", apiKey: "synthetic")
            let restored = try AlibabaSpeechConfiguration(credentials: config.encodedCredentials())
            XCTAssertEqual(restored, config)
            XCTAssertEqual(config.origin.host, "llm-example.\(region.rawValue).maas.aliyuncs.com")
            XCTAssertEqual(config.liveURL.scheme, "wss")
            XCTAssertNoThrow(try config.validateModel(AlibabaSpeechModels.qwen38))
            if region == .beijing || region == .singapore {
                XCTAssertNoThrow(try config.validateModel(AlibabaSpeechModels.funFlash))
            } else {
                XCTAssertThrowsError(try config.validateModel(AlibabaSpeechModels.funFlash))
                XCTAssertThrowsError(try config.validateModel(AlibabaSpeechModels.qwen35))
                XCTAssertThrowsError(try config.validateModel(AlibabaSpeechModels.funLive))
            }
        }
    }

    func testConfiguration_RejectsEndpointSubstitutionAndUnboundKeys() {
        for workspace in ["", "trial", "https://evil.test", "llm-x.evil.test", "x/y", "x?y", "-x", "x-",
                          "user@host", "llm-x:443", "x\nhost", String(repeating: "x", count: 64)] {
            XCTAssertThrowsError(
                try AlibabaSpeechConfiguration(region: .beijing, workspace: workspace, apiKey: "synthetic")
            )
        }
        XCTAssertThrowsError(try AlibabaSpeechConfiguration(credentials: "synthetic"))
        XCTAssertThrowsError(try AlibabaSpeechConfiguration(region: .beijing, workspace: "llm-x", apiKey: "x\nx"))
    }

    func testCatalogue_HasDirectCredentialsAndNoOmniRealtimeClaimOrDesktopFallback() throws {
        for identifier in AlibabaSpeechModels.batchIDs {
            XCTAssertEqual(ModelCatalog.friendlyName(for: identifier),
                           AlibabaSpeechModels.batchOptions.first { $0.id == identifier }?.displayName)
            XCTAssertEqual(ModelCredentialResolver.requirement(for: identifier, purpose: .batchTranscription),
                           .apiKey(identifier: "alibaba.apiKey", providerName: "Alibaba Model Studio"))
            XCTAssertFalse(OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.contains(identifier))
            XCTAssertFalse(DesktopTranscription.batchModels.contains { $0.id == identifier })
            XCTAssertNil(LiveTranscriptionRouting.route(for: identifier))
        }
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: AlibabaSpeechModels.funLive))
        XCTAssertEqual(route.apiModelName, "fun-asr-realtime")
        XCTAssertEqual(route.sampleRate, 16_000)
        XCTAssertTrue(route.isSupportedOnIOS)
        XCTAssertNil(DesktopLiveTranscription.route(forID: route.modelID))
        XCTAssertEqual(ModelCatalog.liveCapabilities(for: route.modelID).postStopFinalizeBudget, 5)
    }

    func testFunFlash_SendsTheExactDedicatedRequestAndReadsDocumentedOutput() async throws {
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        StubURLProtocol.respond { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://llm-example.ap-southeast-1.maas.aliyuncs.com/"
                            + "api/v1/services/aigc/multimodal-generation/generation")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
                as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "fun-asr-flash-2026-06-15")
            let input = try XCTUnwrap(body["input"] as? [String: Any])
            let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
            let audio = try XCTUnwrap(content.first?["input_audio"] as? [String: String])
            XCTAssertEqual(audio["data"], "data:audio/wav;base64,AQIDBA==")
            XCTAssertEqual(audio["format"], "wav")
            let output = Data(#"{"output":{"text":"Hello.","output":{"sentence":{"text":"Hello."}}}}"#.utf8)
            return (self.response(request), output)
        }
        let result = try await AlibabaBatchTranscriptionClient(session: StubURLProtocol.makeSession())
            .transcribeFile(at: file, credentials: credentials(), model: AlibabaSpeechModels.funFlash,
                            duration: 300, language: "Automatic")
        XCTAssertEqual(result.text, "Hello.")
        XCTAssertEqual(result.duration, 300)
        XCTAssertEqual(result.modelIdentifier, AlibabaSpeechModels.funFlash)
    }

    func testFunFlash_ParsesNestedOnlyAndEmptySpeechWithoutInventingText() throws {
        XCTAssertEqual(try AlibabaBatchTranscriptionClient.funTranscript(
            Data(#"{"output":{"output":{"sentence":{"text":"Hello"}}}}"#.utf8)), "Hello")
        XCTAssertEqual(try AlibabaBatchTranscriptionClient.funTranscript(Data(#"{"output":{"text":""}}"#.utf8)), "")
        XCTAssertThrowsError(try AlibabaBatchTranscriptionClient.funTranscript(Data(#"{"output":{}}"#.utf8)))
        XCTAssertThrowsError(try AlibabaBatchTranscriptionClient.funTranscript(Data(#"{"code":"InvalidApiKey"}"#.utf8)))
    }

    func testOmni_RequestUsesTextSSEAndLatestModelDisablesThinking() async throws {
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        for model in [AlibabaSpeechModels.qwen35, AlibabaSpeechModels.qwen38] {
            StubURLProtocol.respond { request in
                XCTAssertEqual(request.url?.path, "/compatible-mode/v1/chat/completions")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
                    as? [String: Any])
                XCTAssertEqual(body["model"] as? String, try AlibabaSpeechModels.apiModel(for: model))
                XCTAssertEqual(body["stream"] as? Bool, true)
                XCTAssertEqual(body["modalities"] as? [String], ["text"])
                XCTAssertEqual(body["reasoning_effort"] as? String,
                               model == AlibabaSpeechModels.qwen38 ? "none" : nil)
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
                XCTAssertTrue(content.first?["text"] as? String ?? "" != "")
                XCTAssertTrue((content.first?["text"] as? String)?.contains("language hint is en") == true)
                return (self.response(request), Self.omniResponse)
            }
            let result = try await AlibabaBatchTranscriptionClient(session: StubURLProtocol.makeSession())
                .transcribeFile(at: file, credentials: credentials(), model: model, duration: 1, language: "en_GB")
            XCTAssertEqual(result.text, "Hello world.")
            XCTAssertEqual(result.modelIdentifier, model)
        }
    }

    func testOmni_RejectsTruncatedAndLengthLimitedSSEAndIgnoresReasoning() throws {
        XCTAssertEqual(try AlibabaBatchTranscriptionClient.omniTranscript(Self.omniResponse), "Hello world.")
        XCTAssertThrowsError(try AlibabaBatchTranscriptionClient.omniTranscript(
            Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"part\"}}]}\n".utf8)))
        XCTAssertThrowsError(try AlibabaBatchTranscriptionClient.omniTranscript(
            Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n".utf8)))
        XCTAssertEqual(try AlibabaBatchTranscriptionClient.omniTranscript(
            Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n".utf8)), "")
    }

    func testBatch_RejectsInvalidDurationSizeModelAndRegionBeforeNetwork() async throws {
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let client = AlibabaBatchTranscriptionClient(session: StubURLProtocol.makeSession())
        for duration in [Double.nan, Double.infinity, -1, 0, 300.001] {
            do {
                _ = try await client.transcribeFile(at: file, credentials: credentials(),
                                                   model: AlibabaSpeechModels.funFlash, duration: duration)
                XCTFail("Invalid duration was accepted")
            } catch { XCTAssertTrue(error is AlibabaSpeechError) }
        }
        do {
            _ = try await client.transcribeFile(at: file, credentials: credentials(region: .frankfurt),
                                               model: AlibabaSpeechModels.funFlash, duration: 1)
            XCTFail("Unsupported region was accepted")
        } catch { XCTAssertEqual(error as? AlibabaSpeechError, .unsupportedRegion) }
        do {
            _ = try await client.transcribeFile(at: file, credentials: credentials(),
                                               model: "alibaba/unknown", duration: 1)
            XCTFail("Unknown model was accepted")
        } catch { XCTAssertEqual(error as? AlibabaSpeechError, .unsupportedModel) }
        try Data(repeating: 1, count: AlibabaBatchTranscriptionClient.maximumAudioBytes + 1).write(to: file)
        do {
            _ = try await client.transcribeFile(at: file, credentials: credentials(),
                                               model: AlibabaSpeechModels.qwen38, duration: 1)
            XCTFail("Oversized inline audio was accepted")
        } catch { XCTAssertEqual(error as? AlibabaSpeechError, .audioTooLarge) }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testBatch_HTTPFailuresAndCancelledTransportRemainVisible() async throws {
        let file = try audioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        for status in [401, 403, 429, 500] {
            StubURLProtocol.respond { request in
                (self.response(request, status: status), Data(#"{"code":"synthetic-error"}"#.utf8))
            }
            do {
                _ = try await AlibabaBatchTranscriptionClient(session: StubURLProtocol.makeSession())
                    .transcribeFile(at: file, credentials: credentials(),
                                    model: AlibabaSpeechModels.funFlash, duration: 1)
                XCTFail("HTTP error was accepted")
            } catch {
                guard case TranscriptionProviderError.httpError(let received, _) = error else {
                    return XCTFail("Incorrect error: \(error)")
                }
                XCTAssertEqual(received, status)
            }
        }
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do {
            _ = try await AlibabaBatchTranscriptionClient(session: StubURLProtocol.makeSession())
                .transcribeFile(at: file, credentials: credentials(),
                                model: AlibabaSpeechModels.funFlash, duration: 1)
            XCTFail("Cancelled transport was accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func audioFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3, 4]).write(to: file)
        return file
    }

    private func credentials(region: AlibabaSpeechConfiguration.Region = .singapore) throws -> String {
        try AlibabaSpeechConfiguration(region: region, workspace: "llm-example", apiKey: "synthetic")
            .encodedCredentials()
    }

    private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static let omniResponse = Data("""
    data: {"choices":[{"index":0,"delta":{"reasoning_content":"do not insert reasoning","content":""}}]}

    data: {"choices":[{"index":0,"delta":{"content":"Hello "}}]}

    data: {"choices":[{"index":0,"delta":{"content":"world."},"finish_reason":"stop"}]}

    data: {"choices":[],"usage":{"completion_tokens":3}}

    data: [DONE]

    """.utf8)
}
