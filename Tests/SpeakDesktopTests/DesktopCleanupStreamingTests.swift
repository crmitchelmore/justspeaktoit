import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest

final class DesktopCleanupStreamingTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testStreaming_UsesCapturedPromptContextAndOnlyFinalOutcome() async throws {
        var options = DesktopPostProcessing.Options(
            mode: .remote, customPrompt: "Keep exact formatting.", outputLanguage: "French",
            temperature: 0.4, includeLexiconDirectives: true, includeContextTags: false
        )
        options.streamingEnabled = true
        let directives = ["Use the name Acme."]
        let expected = TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: options.customPrompt, outputLanguage: options.outputLanguage,
            lexiconDirectives: directives, lexiconContextTags: []
        )
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["temperature"] as? Double, 0.4)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first?["content"], expected)
            XCTAssertEqual(messages.last?["content"], TranscriptCleanupPolicy.userMessage(transcript: "raw"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return .respond(response, Data((
                #"data: {"choices":[{"delta":{"content":"Clean.\n"}}]}"# + "\n\n"
                + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
            ).utf8))
        }
        let updates = CleanupPreviewLog()
        let result = try await DesktopPostProcessing.process(
            rawText: "raw", options: options, apiKey: "captured", lexiconDirectives: directives,
            lexiconContextTags: ["Do not include"], session: StubURLProtocol.makeSession(), localLLM: nil,
            onUpdate: { updates.append($0) }
        )
        XCTAssertEqual(result.original, "raw")
        XCTAssertEqual(result.processedText, "Clean.\n")
        XCTAssertEqual(result.modelIdentifier, options.modelIdentifier)
        XCTAssertEqual(result.systemPrompt, expected)
        XCTAssertEqual(updates.values.last, "Clean.\n")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testEmptyDisabledAndLocalRules_StreamingPreferenceNeverAddsNetwork() async throws {
        for mode in [DesktopPostProcessing.Mode.disabled, .remote, .local] {
            var options = DesktopPostProcessing.Options(
                mode: mode, modelIdentifier: mode == .local
                    ? LocalPostProcessingModel.builtInRulesModelID : ModelCatalog.defaultPostProcessingModel
            )
            options.streamingEnabled = true
            for raw in ["", " \n", "[BLANK_AUDIO]"] {
                let outcome = try await process(raw, options: options)
                XCTAssertEqual(outcome.original, raw)
                XCTAssertEqual(outcome.processedText, "")
            }
            if mode != .remote {
                let outcome = try await process("hello world", options: options)
                XCTAssertEqual(outcome.processedText, mode == .local ? "Hello world" : "hello world")
            }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDownloadedModel_UsesExplicitEngineAndPromptWithoutNetworkPreview() async throws {
        let engine = CleanupLocalEngine()
        var options = DesktopPostProcessing.Options(
            mode: .localLLM,
            modelIdentifier: LocalPostProcessingModel.huggingFaceModelID(repoID: "test/model", filename: "test.gguf"),
            customPrompt: "One full stop after every word."
        )
        options.streamingEnabled = true
        let result = try await DesktopPostProcessing.process(
            rawText: "hello world", options: options, apiKey: "",
            session: StubURLProtocol.makeSession(), localLLM: engine,
            onUpdate: { _ in XCTFail("Completed-only local engine must not fabricate chunks") }
        )
        XCTAssertEqual(result.processedText, "Hello. World.")
        XCTAssertEqual(engine.prompts.first, result.systemPrompt)
        XCTAssertTrue(result.systemPrompt?.hasPrefix(options.customPrompt!) == true)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testUnavailableLocalEngineAndMissingRemoteKey_AreNotNetworkFallbacks() async throws {
        var local = DesktopPostProcessing.Options(
            mode: .localLLM,
            modelIdentifier: LocalPostProcessingModel.huggingFaceModelID(repoID: "test/model", filename: "test.gguf")
        )
        local.streamingEnabled = true
        do { _ = try await process("raw", options: local); XCTFail("Missing local runtime accepted") } catch {
            XCTAssertTrue(error is LocalLLMError)
        }
        var remote = DesktopPostProcessing.Options(mode: .remote)
        remote.streamingEnabled = true
        do { _ = try await process("raw", options: remote); XCTFail("Missing key accepted") } catch {
            guard case OpenRouterClientError.apiKeyMissing = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testLegacyOptionsAndPublicCallArity_KeepOneShotRequest() async throws {
        let legacy = #"{"mode":"remote","modelIdentifier":"MODEL","temperature":0.2}"#
            .replacingOccurrences(of: "MODEL", with: ModelCatalog.defaultPostProcessingModel)
        let options = try JSONDecoder().decode(DesktopPostProcessing.Options.self, from: Data(legacy.utf8))
        XCTAssertFalse(options.streamingEnabled)
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
            )
            XCTAssertNil(body["stream"])
            return .ok(Data(#"{"choices":[{"message":{"content":"Completed only"}}]}"#.utf8))
        }
        let result = try await DesktopPostProcessing.process(
            rawText: "raw", options: options, apiKey: "synthetic", session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(result.processedText, "Completed only")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    func testStreamingOptions_RoundTripTransferAndNativeDescriptorHaveOneAuthority() throws {
        let key = ApplicationPreferenceKey.postProcessingStreamingEnabled.rawValue
        var options: DesktopPostProcessing.Options? = .init()
        let imported = try DesktopConfiguration(values: [
            key: AnyCodable(.bool(true)), "futureCleanup": AnyCodable(.string("retained")),
            "postProcessingEnabled": AnyCodable(.bool(true)),
            "postProcessingModel": AnyCodable(.string(ModelCatalog.defaultPostProcessingModel))
        ])
        let remaining = try DesktopPostProcessingConfiguration.importOptions(from: imported, into: &options)
        XCTAssertEqual(options?.streamingEnabled, true)
        XCTAssertEqual(options?.mode, .disabled, "Preference transfer must not grant a remote route")
        XCTAssertNil(remaining.values[key])
        XCTAssertEqual(remaining.values["futureCleanup"], imported.values["futureCleanup"])
        let encoded = try JSONEncoder().encode(options)
        let restored = try JSONDecoder().decode(DesktopPostProcessing.Options?.self, from: encoded)
        XCTAssertEqual(restored, options)
        let exported = try DesktopPostProcessingConfiguration.exportOptions(restored, over: remaining)
        XCTAssertEqual(exported.values[key], AnyCodable(.bool(true)))
        XCTAssertEqual(DesktopConfiguration.fields.filter { $0.key == key }.count, 1)
        XCTAssertTrue(try DesktopConfiguration().enabled(key))
        XCTAssertTrue(SpeechDefaults.postProcessingStreamingEnabled)
        XCTAssertFalse(DesktopPostProcessing.Options().streamingEnabled, "Legacy desktop API behavior stays one-shot")
    }

    func testInvalidStreamingImport_DoesNotMutateExistingOptions() throws {
        var options: DesktopPostProcessing.Options? = .init(mode: .disabled)
        options?.streamingEnabled = true
        let before = options
        XCTAssertThrowsError(try DesktopPostProcessingConfiguration.importOptions(
            from: DesktopConfiguration(values: ["postProcessingStreamingEnabled": AnyCodable(.string("true"))]),
            into: &options
        ))
        XCTAssertEqual(options, before)
    }

    private func process(
        _ raw: String, options: DesktopPostProcessing.Options
    ) async throws -> DesktopPostProcessing.Outcome {
        try await DesktopPostProcessing.process(
            rawText: raw, options: options, apiKey: "", session: StubURLProtocol.makeSession(), localLLM: nil,
            onUpdate: { _ in XCTFail("No preview expected for this route") }
        )
    }
}

private final class CleanupLocalEngine: DesktopLocalLLMEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var prompts: [String] { lock.withLock { stored } }
    func complete(
        modelIdentifier: String, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String {
        lock.withLock { stored.append(systemPrompt) }
        return "Hello. World."
    }
}
