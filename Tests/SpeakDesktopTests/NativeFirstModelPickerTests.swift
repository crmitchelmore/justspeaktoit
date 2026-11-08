import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakDesktop
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// Native-first picker grouping, routing and migration (shared by every platform).
final class NativeFirstModelPickerTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Routing

    func testNativeSelectionResolvesToItsProviderAndModel() throws {
        let luna = try XCTUnwrap(NativeTextModels.route(for: "native/openai/gpt-6-luna"))
        XCTAssertEqual(luna.provider, NativeTextModels.openAI)
        XCTAssertEqual(luna.model, "gpt-6-luna")

        // Groq model names contain a slash; only the first segment names the provider.
        let groq = try XCTUnwrap(NativeTextModels.route(for: "native/groq/openai/gpt-oss-120b"))
        XCTAssertEqual(groq.provider, NativeTextModels.groq)
        XCTAssertEqual(groq.model, "openai/gpt-oss-120b")

        XCTAssertNil(NativeTextModels.route(for: "openai/gpt-6-luna"), "OpenRouter slugs are never native")
        XCTAssertNil(NativeTextModels.route(for: "native/unknown/model"))
        XCTAssertNil(NativeTextModels.route(for: "native/openai/"))
    }

    func testNativeModelsUseTheirProviderKeyAndOpenRouterSlugsKeepOpenRouter() {
        XCTAssertEqual(
            ModelCredentialResolver.requirement(for: "native/openai/gpt-6-luna", purpose: .postProcessing),
            .apiKey(identifier: "openai.apiKey", providerName: "OpenAI")
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(for: "native/google/gemini-2.5-flash", purpose: .postProcessing),
            .apiKey(identifier: "google.apiKey", providerName: "Google Gemini")
        )
        // The model that was mis-routed: same name, but its saved identifier is an OpenRouter slug.
        XCTAssertEqual(
            ModelCredentialResolver.requirement(for: "openai/gpt-6-luna", purpose: .postProcessing),
            ModelCredentialResolver.openRouterRequirement
        )
        for provider in NativeTextModels.providers {
            XCTAssertTrue(
                ModelCredentialResolver.allKnownAPIKeyIdentifiers.contains(provider.credentialIdentifier),
                "\(provider.id) has no existing credential slot"
            )
        }
    }

    func testNativeRequestGoesToProviderWithoutOpenRouterModelOrUnsupportedTemperature() throws {
        let target = try ChatCompletionTarget.resolve("native/openai/gpt-6-luna")
        XCTAssertEqual(target.url.host, "api.openai.com")
        XCTAssertFalse(target.isOpenRouter)

        let request = OpenRouterChatRequest(
            model: "native/openai/gpt-6-luna", temperature: 0.2,
            messages: [.init(role: "user", content: "fixture")], stream: nil, maxTokens: 32
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "gpt-6-luna")
        XCTAssertNil(object["temperature"])
        XCTAssertEqual(object["max_completion_tokens"] as? Int, 32)
        XCTAssertNil(object["max_tokens"])

        let openRouter = try ChatCompletionTarget.resolve("openai/gpt-6-luna")
        XCTAssertEqual(openRouter.url.host, "openrouter.ai")
        XCTAssertTrue(openRouter.isOpenRouter)
        XCTAssertEqual(openRouter.model, "openai/gpt-6-luna")
    }

    func testChatClientSendsNativeSelectionToTheProviderEndpoint() async throws {
        let reply = Data(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"content":"Done."}}]}"#.utf8)
        StubURLProtocol.handler = { .ok(reply, url: $0.url!) }
        let client = OpenRouterChatClient(apiKey: "native-key", session: StubURLProtocol.makeSession())

        _ = try await client.sendChat(
            systemPrompt: nil, messages: [.init(role: .user, content: "hi")],
            model: "native/google/gemini-3.1-flash-lite", temperature: 0.2
        )
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"), "OpenRouter branding must not leak")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "gemini-3.1-flash-lite")
    }

    func testAPIClientUsesTheNativeKeyAndNeverFallsBackToOpenRouter() async {
        let withNative = OpenRouterAPIClient(
            apiKey: "openrouter-key", nativeAPIKeyProvider: { $0 == "openai.apiKey" ? "openai-key" : nil }
        )
        let hasOpenAI = await withNative.hasStoredAPIKey(forModel: "native/openai/gpt-6-luna")
        let hasGoogle = await withNative.hasStoredAPIKey(forModel: "native/google/gemini-2.5-flash")
        let hasOpenRouter = await withNative.hasStoredAPIKey(forModel: "openai/gpt-6-luna")
        XCTAssertTrue(hasOpenAI)
        XCTAssertFalse(hasGoogle, "an OpenRouter key must not satisfy a native route")
        XCTAssertTrue(hasOpenRouter)

        do {
            _ = try await withNative.sendChat(
                systemPrompt: nil, messages: [.init(role: .user, content: "hi")],
                model: "native/google/gemini-2.5-flash", temperature: 0.2
            )
            XCTFail("a missing native key must fail rather than use OpenRouter or local fallback")
        } catch {
            XCTAssertEqual(error as? NativeTextModelError, .apiKeyMissing(providerName: "Google Gemini"))
        }
    }

    // MARK: - Migration

    func testSavedOpenRouterSelectionsKeepTheirRoute() {
        for saved in ["openai/gpt-6-luna", "openai/gpt-5.6-luna", "openai/gpt-5-mini",
                      CleanupModelSelection.prefix + "openai/future-model"] {
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(saved), saved)
            XCTAssertTrue(ModelPickerGrouping.isOpenRouter(saved, purpose: .postProcessing), saved)
        }
        for native in NativeTextModels.postProcessing.map(\.id) {
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(native), native)
        }
        XCTAssertEqual(ModelCatalog.defaultPostProcessingModel, "openai/gpt-5-mini")
    }

    // MARK: - Grouping and ordering

    func testNativeRoutesComeFirstAndOpenRouterIsOneSeparateGroup() {
        let groups = ModelPickerGrouping.groups(ModelCatalog.postProcessing, purpose: .postProcessing)
        XCTAssertFalse(groups.direct.isEmpty)
        XCTAssertFalse(groups.openRouter.isEmpty)
        XCTAssertTrue(groups.direct.allSatisfy { !ModelPickerGrouping.isOpenRouter($0.id, purpose: .postProcessing) })
        XCTAssertTrue(groups.openRouter.allSatisfy {
            ModelPickerGrouping.isOpenRouter($0.id, purpose: .postProcessing)
        })
        XCTAssertEqual(
            Set(groups.direct.filter { NativeTextModels.isNative($0.id) }.map(\.id)),
            Set(NativeTextModels.postProcessing.map(\.id))
        )
        // A model available both ways is never a top-level OpenRouter entry.
        XCTAssertTrue(groups.direct.contains { $0.id == "native/openai/gpt-6-luna" })
        XCTAssertFalse(groups.direct.contains { $0.id == "openai/gpt-6-luna" })

        let cloud = ModelCatalog.cloudPostProcessing
        let lastNative = cloud.lastIndex { NativeTextModels.isNative($0.id) } ?? -1
        let firstOpenRouter = cloud.firstIndex { ModelPickerGrouping.isOpenRouter($0.id, purpose: .postProcessing) }
        XCTAssertLessThan(lastNative, firstOpenRouter ?? Int.max, "native entries precede OpenRouter")
    }

    func testCatalogueIDsAreUnique() {
        XCTAssertEqual(Set(ModelCatalog.postProcessing.map(\.id)).count, ModelCatalog.postProcessing.count)
    }

    // MARK: - Alphabetical ordering

    func testEachGroupIsAlphabeticalByProviderThenModel() {
        let groups = ModelPickerGrouping.groups(ModelCatalog.cloudPostProcessing, purpose: .postProcessing)
        for group in [groups.direct, groups.openRouter] {
            let keys = group.map {
                (ModelPickerGrouping.providerName(for: $0.id, purpose: .postProcessing), $0.displayName)
            }
            for (lhs, rhs) in zip(keys, keys.dropFirst()) {
                let providerOrder = ModelPickerGrouping.ordered(lhs.0, rhs.0)
                XCTAssertNotEqual(providerOrder, false, "\(lhs.0) listed before \(rhs.0)")
                if providerOrder == nil {
                    XCTAssertNotEqual(ModelPickerGrouping.ordered(lhs.1, rhs.1), false, "\(lhs.1) before \(rhs.1)")
                }
            }
        }
        XCTAssertEqual(
            groups.direct.map { ModelPickerGrouping.providerName(for: $0.id, purpose: .postProcessing) }.uniqued(),
            ["Google Gemini", "Groq", "Mistral", "OpenAI"]
        )
        XCTAssertEqual(groups.direct.first?.id, "native/google/gemini-2.5-flash")
    }

    func testOpenRouterGroupSortsByVendorPrefix() {
        let groups = ModelPickerGrouping.groups(ModelCatalog.cloudPostProcessing, purpose: .postProcessing)
        let vendors = groups.openRouter.map { ModelPickerGrouping.providerName(for: $0.id, purpose: .postProcessing) }
            .uniqued()
        XCTAssertEqual(vendors, ["Anthropic", "Google", "Meta Llama", "Mistral", "OpenAI", "Qwen"])
        XCTAssertEqual(
            ModelPickerGrouping.providerName(for: CleanupModelSelection.prefix + "openai/x", purpose: .postProcessing),
            "OpenAI"
        )
    }

    func testOrderingIsCaseInsensitiveNumericAndStable() {
        let options = ["gpt-5.10", "GPT-5.4", "gpt-5.4 mini", "Alpha", "alpha"].enumerated().map {
            ModelCatalog.Option(id: "openai/m\($0.offset)", displayName: $0.element)
        }
        let sorted = ModelPickerGrouping.sortedByProvider(options, purpose: .postProcessing)
        XCTAssertEqual(sorted.map(\.displayName), ["Alpha", "alpha", "GPT-5.4", "gpt-5.4 mini", "gpt-5.10"])
        XCTAssertNil(ModelPickerGrouping.ordered("openai", "OpenAI"))
    }

    func testGroupingDropsDuplicatesAndTheCustomEntry() {
        let luna = ModelCatalog.Option(id: "openai/gpt-6-luna", displayName: "GPT-6 Luna")
        let native = ModelCatalog.Option(id: "native/openai/gpt-6-luna", displayName: "GPT-6 Luna")
        let custom = ModelCatalog.Option(id: ModelCatalog.customOptionID, displayName: "Custom")
        let groups = ModelPickerGrouping.groups([luna, native, luna, custom, native], purpose: .postProcessing)
        XCTAssertEqual(groups.direct.map(\.id), [native.id])
        XCTAssertEqual(groups.openRouter.map(\.id), [luna.id])
    }

    func testSelectionLabelNamesTheOpenRouterRoute() {
        XCTAssertEqual(
            ModelPickerGrouping.selectionLabel(
                for: "openai/gpt-6-luna", displayName: "GPT-6 Luna", purpose: .postProcessing
            ),
            "OpenRouter › GPT-6 Luna"
        )
        XCTAssertEqual(
            ModelPickerGrouping.selectionLabel(
                for: "native/openai/gpt-6-luna", displayName: "GPT-6 Luna", purpose: .postProcessing
            ),
            "GPT-6 Luna"
        )
    }

    func testBatchTranscriptionGroupsFollowTheSameRule() {
        let groups = ModelPickerGrouping.groups(ModelCatalog.batchTranscription, purpose: .batchTranscription)
        XCTAssertFalse(groups.direct.isEmpty)
        XCTAssertFalse(groups.openRouter.isEmpty)
        XCTAssertTrue(groups.openRouter.allSatisfy {
            ModelCredentialResolver.requirement(for: $0.id, purpose: .batchTranscription)
                == ModelCredentialResolver.openRouterRequirement
        })
    }

    func testFlatDesktopListLabelsOpenRouterAndKeepsIdentifiers() {
        let flat = ModelPickerGrouping.flattened(ModelCatalog.cloudPostProcessing, purpose: .postProcessing)
        XCTAssertEqual(Set(flat.map(\.id)), Set(ModelCatalog.cloudPostProcessing.map(\.id)))
        guard let firstOpenRouter = flat.firstIndex(where: { $0.displayName.hasPrefix("OpenRouter › ") }) else {
            return XCTFail("OpenRouter entries are not labelled")
        }
        XCTAssertTrue(flat[..<firstOpenRouter].allSatisfy { NativeTextModels.isNative($0.id) })
        XCTAssertEqual(DesktopPostProcessing.remoteModels.first?.id, "native/google/gemini-2.5-flash")
    }

    func testSearchMatchesNameIdentifierAndDescription() {
        let options = ModelCatalog.cloudPostProcessing
        XCTAssertEqual(ModelPickerGrouping.filter(options, query: "  ").count, options.count)
        XCTAssertTrue(ModelPickerGrouping.filter(options, query: "qwen").allSatisfy {
            $0.id.lowercased().contains("qwen") || $0.displayName.lowercased().contains("qwen")
                || ($0.description?.lowercased().contains("qwen") ?? false)
        })
        XCTAssertFalse(ModelPickerGrouping.filter(options, query: "qwen").isEmpty)
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        reduce(into: []) { result, value in if result.last != value { result.append(value) } }
    }
}
