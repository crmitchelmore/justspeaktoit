import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakDesktop
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class CleanupModelDiscoveryTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testTrustRequiresTextChatMetadataAndKnownAuthor() throws {
        var candidates = [entry("openai/future-model")]
        candidates += [entry("unknown/future-model"), entry("openai.evil/future-model"), entry("openai/../evil")]
        candidates += [entry("openai/audio", outputs: ["audio", "text"])]
        candidates += [entry("openai/embedding", outputs: ["embeddings"])]
        candidates += [entry("openai/instruct", endpoints: ["/api/v1/completions"])]
        candidates += [["id": "openai/bare-list", "owned_by": "openai"]]
        var retired = entry("openai/retired")
        retired["expiration_date"] = "2026-01-01"
        candidates += [retired, entry("openai/future-model")]
        let models = try decode(candidates)
        XCTAssertEqual(models.map(\.id), ["openai/future-model"])
        XCTAssertEqual(models.first?.inputPrice, 0.1)
        XCTAssertEqual(models.first?.outputPrice, 0.5)
        XCTAssertEqual(models.first?.contextLength, 1_050_000)
        XCTAssertNil(models.first?.option.estimatedLatencyMs)
        XCTAssertEqual(models.first?.option.tags, [])
    }

    func testMissingAndInvalidPricesRemainUnknownAndExtraPricingFieldsAreIgnored() throws {
        var missing = entry("openai/missing")
        missing.removeValue(forKey: "pricing")
        missing.removeValue(forKey: "context_length")
        var invalid = entry("openai/invalid")
        invalid["pricing"] = ["prompt": "-1", "completion": "NaN"]
        let models = try decode([missing, invalid, entry("openai/known")])
        XCTAssertNil(models.first { $0.id == "openai/missing" }?.option.pricing)
        XCTAssertNil(models.first { $0.id == "openai/missing" }?.contextLength)
        XCTAssertNil(models.first { $0.id == "openai/invalid" }?.option.pricing)
        XCTAssertEqual(models.first { $0.id == "openai/known" }?.outputPrice, 0.5)
    }

    func testDisabledDiscoveryMakesNoRequestAndKeepsBundledDefaults() async throws {
        let store = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
        await store.refresh(force: true)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertEqual(store.options(), ModelCatalog.cloudPostProcessing)
        XCTAssertEqual(ModelCatalog.defaultPostProcessingModel, "openai/gpt-5.6-luna")
        XCTAssertFalse(try DesktopConfiguration().enabled(CleanupModelSelection.preferenceKey))
    }

    func testRefreshIsMetadataOnlyDeduplicatesBundledRoutesAndBoundsRetries() async throws {
        let response = try body([entry("openai/future-model"), entry("openai/gpt-6-luna")])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            return .ok(response, url: request.url!)
        }
        let store = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
        store.setEnabled(true)
        await store.refresh()
        await store.refresh(force: true)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertTrue(store.options().contains { $0.id == "openrouter/cleanup/openai/future-model" })
        XCTAssertFalse(store.options().contains { $0.id == "openrouter/cleanup/openai/gpt-6-luna" })
        XCTAssertEqual(store.options().filter { $0.id == "openai/gpt-6-luna" },
                       ModelCatalog.cloudPostProcessing.filter { $0.id == "openai/gpt-6-luna" })
        store.setEnabled(false)
        XCTAssertEqual(store.options(), ModelCatalog.cloudPostProcessing)
        XCTAssertTrue(store.options(selected: "openrouter/cleanup/openai/future-model").contains {
            $0.id == "openrouter/cleanup/openai/future-model"
        })
    }

    func testSavedDiscoverySurvivesDisabledCacheAndDesktopMigration() {
        let selection = "openrouter/cleanup/openai/future-model"
        XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(selection), selection)
        XCTAssertEqual(ModelRouting.family(for: selection), .postProcessing(provider: "openrouter"))
        XCTAssertEqual(ModelCredentialResolver.requirement(for: selection, purpose: .postProcessing),
                       .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter"))
        XCTAssertEqual(DesktopPostProcessing.mode(for: selection), .remote)
        let options = DesktopPostProcessing.Options(mode: .remote, modelIdentifier: selection)
        XCTAssertEqual(DesktopPostProcessing.migrated(options).modelIdentifier, selection)
        XCTAssertTrue(DesktopPostProcessing.nativeModels(selected: selection).contains { $0.id == selection })
        XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel("openrouter/cleanup/evil/model"),
                       ModelCatalog.defaultPostProcessingModel)
        XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel("unknown/model"),
                       ModelCatalog.defaultPostProcessingModel)
        var local = DesktopPostProcessing.Options(mode: .local,
            modelIdentifier: LocalPostProcessingModel.builtInRulesModelID)
        local.lastRemoteModelIdentifier = selection
        let choices = DesktopPostProcessing.nativeModels(selected: local.modelIdentifier, rememberedRemote: selection)
        XCTAssertEqual(DesktopPostProcessing.remoteSelection(for: local), choices.firstIndex { $0.id == selection })
        XCTAssertNotNil(DesktopPostProcessing.remoteSelection(for: local))
    }

    func testRequestEncoderUnwrapsOnlyValidatedExplicitDiscoveryForBothModes() throws {
        for streaming: Bool? in [nil, true] {
            let request = OpenRouterChatRequest(
                model: "openrouter/cleanup/openai/future-model", temperature: 0.2,
                messages: [.init(role: "user", content: "fixture")], stream: streaming, maxTokens: 32
            )
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "openai/future-model")
            XCTAssertEqual(object["stream"] as? Bool, streaming)
            XCTAssertEqual(object["max_tokens"] as? Int, 32)
        }
        let invalid = OpenRouterChatRequest(model: "openrouter/cleanup/evil/model", temperature: 0.2,
                                            messages: [], stream: nil, maxTokens: nil)
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    func testGoodCacheSurvivesNetworkFailureAndExpiresSafely() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try body([entry("openai/future-model")])
        StubURLProtocol.handler = { .ok(response, url: $0.url!) }
        let original = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: cache,
                                                 clock: { date })
        original.setEnabled(true)
        await original.refresh()
        let persisted = try Data(contentsOf: cache)
        let text = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(text.contains("private_field"))
        XCTAssertFalse(text.contains("description"))
        let later = date.addingTimeInterval(CleanupModelDiscoveryStore.cacheLifetime + 1)
        let reopened = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: cache,
                                                 clock: { later })
        reopened.setEnabled(true)
        StubURLProtocol.handler = { .ok(Data("not json".utf8), url: $0.url!) }
        await reopened.refresh()
        XCTAssertNotNil(reopened.snapshot.errorMessage)
        XCTAssertEqual(reopened.snapshot.models.map(\.id), ["openai/future-model"])
        XCTAssertEqual(try Data(contentsOf: cache), persisted)
        let expired = CleanupModelDiscoveryStore(cacheURL: cache,
            clock: { date.addingTimeInterval(CleanupModelDiscoveryStore.maximumCacheAge + 1) })
        expired.setEnabled(true)
        XCTAssertEqual(expired.options(), ModelCatalog.cloudPostProcessing)
        let future = CleanupModelDiscoveryStore(cacheURL: cache, clock: { date.addingTimeInterval(-1) })
        XCTAssertTrue(future.snapshot.models.isEmpty)
    }

    func testNativePreferenceIsOffByDefaultAndRoundTripsWithoutChangingModel() throws {
        XCTAssertEqual(CleanupModelSelection.preferenceKey,
                       ApplicationPreferenceKey.cleanupModelDiscoveryEnabled.rawValue)
        XCTAssertNil(DataMigrationPreferenceCatalog.definition(for: CleanupModelSelection.preferenceKey))
        let configuration = try DesktopConfiguration()
        var entries = configuration.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == CleanupModelSelection.preferenceKey
        })
        XCTAssertFalse(configuration.enabled(CleanupModelSelection.preferenceKey))
        entries[index] = "1"
        let changed = try configuration.applying(entries)
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(changed))
        XCTAssertTrue(restored.enabled(CleanupModelSelection.preferenceKey))
        XCTAssertEqual(restored.text("postProcessingOutputLanguage"),
                       configuration.text("postProcessingOutputLanguage"))
        XCTAssertEqual(ModelCatalog.defaultPostProcessingModel, "openai/gpt-5.6-luna")
    }

    private func entry(_ id: String, outputs: [String] = ["text"],
                       endpoints: [String] = ["/api/v1/chat/completions"]) -> [String: Any] {
        ["id": id, "name": "OpenAI model", "private_field": "do not persist", "description": "Untrusted prose",
         "architecture": ["input_modalities": ["text", "image"], "output_modalities": outputs],
         "endpoints": endpoints, "context_length": 1_050_000,
         "pricing": ["prompt": "0.0000001", "completion": "0.0000005", "overrides": [["prompt": "0.1"]]]]
    }
    private func body(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": entries])
    }
    private func decode(_ entries: [[String: Any]]) throws -> [DiscoveredCleanupModel] {
        try JSONDecoder().decode(CleanupModelResponse.self, from: body(entries)).data
    }
}
