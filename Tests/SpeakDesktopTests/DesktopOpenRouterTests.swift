import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

/// How OpenRouter batch routes project on desktop hosts: the static audio-capable chat
/// models and saved dynamic `openrouter/transcription/…` selections both resolve the
/// OpenRouter credential, never the credential their identifier prefix suggests.
final class DesktopOpenRouterProjectionTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStaticAudioChatModelsAreDerivedFromCanonicalCredentialOwnership() {
        let openRouterOwned = ModelCatalog.batchTranscription.map(\.id).filter {
            ModelCredentialResolver.requirement(for: $0, purpose: .batchTranscription)
                == .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
        }
        XCTAssertEqual(OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs, Set(openRouterOwned))
        XCTAssertEqual(openRouterOwned.count, 3)
        for identifier in openRouterOwned {
            XCTAssertFalse(OpenAITranscriptionModels.directBatchModelIDs.contains(identifier), identifier)
            XCTAssertFalse(GeminiTranscribeModels.directBatchModelIDs.contains(identifier), identifier)
            XCTAssertTrue(DesktopTranscription.batchModels.contains { $0.id == identifier }, identifier)
            XCTAssertFalse(DesktopTranscription.requiresCanonicalPCM16WAV(model: identifier), identifier)
        }
        // Every remote entry of the canonical batch catalogue now has a desktop route.
        let remote = ModelCatalog.batchTranscription.filter { !$0.id.hasPrefix("apple/") }
        XCTAssertEqual(DesktopTranscription.batchModels, remote)
    }

    func testOpenRouterRoutesUseTheOpenRouterCredentialNotTheIdentifierPrefix() throws {
        let dynamic = OpenRouterTranscriptionSelection.identifier(for: "vendor/model:free")
        for identifier in OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.union([dynamic]) {
            let descriptor = try XCTUnwrap(DesktopTranscription.provider(for: identifier), identifier)
            XCTAssertEqual(descriptor.id, OpenRouterService.providerID)
            XCTAssertEqual(descriptor.displayName, "OpenRouter")
            XCTAssertEqual(descriptor.apiKeyIdentifier, "openrouter.apiKey")
            XCTAssertEqual(descriptor.apiKeyLabel, "OpenRouter API Key")
            XCTAssertEqual(descriptor.apiKeyURL, OpenRouterService.apiKeysURL)
            XCTAssertEqual(
                ModelCredentialResolver.requirement(for: identifier, purpose: .batchTranscription),
                .apiKey(identifier: descriptor.apiKeyIdentifier, providerName: descriptor.displayName)
            )
        }
        // Dynamic selections are routable without joining the static projection.
        XCTAssertFalse(DesktopTranscription.batchModels.contains { $0.id == dynamic })
    }

    func testMalformedDynamicSelectionsAndUnknownChatIdentifiersAreNotRoutable() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let rejected = [
            "openrouter/transcription/", "openrouter/transcription/model", "openrouter/transcription//model",
            "openrouter/transcription/vendor/mo del", "openrouter/speech/anything", "openrouter/whisper-large-v3",
            "openrouter/transcription/vendor/" + String(repeating: "m", count: 600),
            "google/gemini-9.9-imaginary", "openai/gpt-4o-audio-preview-2099-01-01", "vendor/model"
        ]
        for identifier in rejected {
            XCTAssertNil(DesktopTranscription.provider(for: identifier), identifier)
            XCTAssertFalse(DesktopTranscription.batchModels.contains { $0.id == identifier }, identifier)
            do {
                _ = try await DesktopOpenRouterFixture.transcribe(audio, model: identifier)
                XCTFail("Expected \(identifier) to be unsupported")
            } catch {
                guard case DesktopTranscriptionError.unsupportedModel = error else {
                    return XCTFail("\(identifier): \(error)")
                }
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDiscoveredModelsProjectOnlyTranscriptionCapabilityWithoutDuplicates() throws {
        let discovered = try JSONDecoder().decode([OpenRouterAudioModel].self, from: Data(Self.discovery.utf8))
        let staticOptions = DesktopTranscription.batchModels
        let options = DesktopTranscription.batchModels(includingDiscovered: discovered + discovered)
        XCTAssertEqual(Array(options.prefix(staticOptions.count)), staticOptions)
        let dynamic = Array(options.dropFirst(staticOptions.count))
        XCTAssertEqual(dynamic.map(\.id), [
            "openrouter/transcription/vendor/stt", "openrouter/transcription/vendor/both"
        ])
        XCTAssertEqual(dynamic.map(\.displayName), ["Vendor STT", "vendor/both"])
        XCTAssertEqual(dynamic.map(\.description), ["Multilingual", nil])
        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
        for option in dynamic {
            XCTAssertEqual(DesktopTranscription.provider(for: option.id)?.apiKeyIdentifier, "openrouter.apiKey")
        }
        XCTAssertEqual(DesktopTranscription.batchModels(includingDiscovered: []), staticOptions)
    }

    private static let discovery = """
    [{"id":"vendor/stt","name":"Vendor STT","description":"Multilingual",
      "architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}},
     {"id":"vendor/tts","name":"Vendor TTS",
      "architecture":{"input_modalities":["text"],"output_modalities":["speech"]}},
     {"id":"vendor/chat","name":"Vendor chat",
      "architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
     {"id":"vendor/both",
      "architecture":{"input_modalities":["audio","text"],"output_modalities":["speech","transcription"]}}]
    """
}

/// Execution of both OpenRouter routes through the desktop entry point.
final class DesktopOpenRouterRouteTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Static audio-chat route

    func testStaticAudioChatModelsUseOpenRouterChatCompletionsWithInlineAudio() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        let branding = OpenRouterBranding.platformDefault
        for model in OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.sorted() {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), branding.title)
                XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), branding.referer)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), branding.referer)
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
                )
                XCTAssertEqual(body["model"] as? String, model)
                XCTAssertEqual(body["temperature"] as? Double, 0)
                XCTAssertEqual(body["stream"] as? Bool, false)
                XCTAssertNil(body["max_tokens"])
                XCTAssertNil(body["input_audio"])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertEqual(messages.count, 1)
                XCTAssertEqual(messages[0]["role"] as? String, "user")
                let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "input_audio"])
                XCTAssertEqual(
                    content[0]["text"] as? String,
                    "Transcribe this audio file using locale en_GB. "
                        + "Return only the transcript text, with no commentary."
                )
                let input = try XCTUnwrap(content[1]["input_audio"] as? [String: String])
                XCTAssertEqual(input["format"], "wav")
                XCTAssertEqual(input["data"], bytes.base64EncodedString())
                return .ok(Data(Self.chatResponse.utf8), url: request.url!)
            }
            let result = try await DesktopOpenRouterFixture.transcribe(audio, model: model)
            XCTAssertEqual(result.text, "Hello OpenRouter")
            XCTAssertEqual(result.modelIdentifier, model)
            XCTAssertEqual(result.duration, 7)
            XCTAssertEqual(result.segments.map(\.text), ["Hello OpenRouter"])
            XCTAssertEqual(result.segments.first?.endTime, 7)
            XCTAssertNil(result.cost)
            XCTAssertEqual(result.rawPayload, Self.chatResponse)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        }
    }

    func testStaticRouteCancellationStopsTheRequestAndKeepsTheRecording() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = try XCTUnwrap(OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.sorted().first)
        StubURLProtocol.handler = { _ in .hang }
        try await assertCancellationStopsTransport(audio, model: model)
    }

    // MARK: - Dynamic dedicated speech-to-text route

    func testDynamicSelectionUsesTheDedicatedEndpointAndKeepsThePrefixedIdentifier() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)
        let selection = OpenRouterTranscriptionSelection.identifier(for: "vendor/stt-model:beta")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), OpenRouterBranding.platformDefault.title)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "vendor/stt-model:beta")
            XCTAssertEqual(body["response_format"] as? String, "json")
            XCTAssertEqual(body["language"] as? String, "en_GB")
            XCTAssertNil(body["messages"])
            let input = try XCTUnwrap(body["input_audio"] as? [String: String])
            XCTAssertEqual(input["format"], "wav")
            XCTAssertEqual(input["data"], bytes.base64EncodedString())
            return .ok(Data(Self.dedicatedResponse.utf8), url: request.url!)
        }
        let result = try await DesktopOpenRouterFixture.transcribe(audio, model: selection)
        XCTAssertEqual(result.text, "Hello dedicated")
        XCTAssertEqual(result.modelIdentifier, selection)
        XCTAssertEqual(result.duration, 4.5)
        XCTAssertEqual(result.segments.map(\.text), ["Hello dedicated"])
        XCTAssertEqual(result.cost?.inputTokens, 3)
        XCTAssertEqual(result.cost?.outputTokens, 2)
        XCTAssertEqual(result.cost?.currency, "USD")
        let cost = try XCTUnwrap(result.cost?.totalCost)
        XCTAssertEqual(NSDecimalNumber(decimal: cost).doubleValue, 0.012, accuracy: 1e-9)
        XCTAssertNil(result.rawPayload)
        XCTAssertNil(result.debugInfo)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testDynamicSelectionProviderFailuresNeverExposeBodiesAndKeepTheRecording() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let selection = OpenRouterTranscriptionSelection.identifier(for: "vendor/stt")
        for status in [401, 429] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { request in
                .status(
                    status, Data("secret body desktop-test".utf8), url: request.url!,
                    headers: ["Content-Type": "application/json"]
                )
            }
            do {
                _ = try await DesktopOpenRouterFixture.transcribe(audio, model: selection)
                XCTFail("Expected HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? OpenRouterAudioError, .httpStatus(status))
                XCTAssertFalse(error.localizedDescription.contains("secret body"))
                XCTAssertFalse(error.localizedDescription.contains("desktop-test"))
            }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    func testDynamicSelectionEmptyTranscriptStaysEmpty() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in .ok(Data(#"{"text":""}"#.utf8), url: request.url!) }
        let selection = OpenRouterTranscriptionSelection.identifier(for: "vendor/stt")
        let result = try await DesktopOpenRouterFixture.transcribe(audio, model: selection)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.duration, 0)
        XCTAssertNil(result.cost)
    }

    func testDynamicSelectionCapsInlineInputAtTwentyFiveMebibytes() async throws {
        let limit = 25 * 1024 * 1024
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: audio.path, contents: Data(count: limit + 1)))
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { _ in
            XCTFail("Oversized audio must not be uploaded")
            return .hang
        }
        let selection = OpenRouterTranscriptionSelection.identifier(for: "vendor/stt")
        do {
            _ = try await DesktopOpenRouterFixture.transcribe(audio, model: selection)
            XCTFail("Expected the input cap")
        } catch OpenRouterClientError.audioFileTooLarge(let fileSize, let reportedLimit) {
            XCTAssertEqual(fileSize, Int64(limit + 1))
            XCTAssertEqual(reportedLimit, Int64(limit))
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDynamicSelectionCancellationStopsTheRequestAndKeepsTheRecording() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"text":"partial"#.utf8)
            )
        }
        let selection = OpenRouterTranscriptionSelection.identifier(for: "vendor/stt")
        try await assertCancellationStopsTransport(audio, model: selection)
    }

    func testPreCancelledDynamicSelectionNeverStartsARequest() async throws {
        let audio = try DesktopOpenRouterFixture.audio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let selection = OpenRouterTranscriptionSelection.identifier(for: "vendor/stt")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DesktopOpenRouterFixture.transcribe(audio, model: selection)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private func assertCancellationStopsTransport(_ audio: URL, model: String) async throws {
        let inFlight = expectation(description: "Request in flight")
        let stopped = expectation(description: "Transport cancelled")
        StubURLProtocol.onStartLoading = { inFlight.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let task = Task { try await DesktopOpenRouterFixture.transcribe(audio, model: model) }
        await fulfillment(of: [inFlight], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    private static let chatResponse = #"""
    {"choices":[{"index":0,"message":{"role":"assistant","content":"  \n"}},
     {"index":1,"finish_reason":"stop","message":{"role":"assistant","content":"  Hello OpenRouter \n"}}],
     "usage":{"prompt_tokens":10,"completion_tokens":2}}
    """#

    private static let dedicatedResponse =
        #"{"text":"Hello dedicated","usage":{"seconds":4.5,"cost":0.012,"input_tokens":3,"output_tokens":2}}"#
}

private enum DesktopOpenRouterFixture {
    static func transcribe(_ audio: URL, model: String) async throws -> TranscriptionResult {
        try await DesktopTranscription.transcribe(
            audioURL: audio, model: model, apiKey: "  desktop-test  ", duration: 7,
            language: "en_GB", session: StubURLProtocol.makeSession()
        )
    }

    static func audio() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        return audio
    }
}
