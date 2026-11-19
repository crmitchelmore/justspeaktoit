import XCTest
@testable import SpeakCore

/// `OpenRouterAPIClient` is Apple-only, so its native-routing checks live here;
/// the portable routing tests are in SpeakDesktopTests.
final class NativeTextModelAPIClientTests: XCTestCase {
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

    func testAnthropicKeyIsTransferableButNotCloudSynced() {
        XCTAssertTrue(ConfigTransferManager.transferableSecretIdentifiers.contains("anthropic.apiKey"))
        XCTAssertFalse(ProviderCredentialCatalogue.cloudKitSyncable.contains("anthropic.apiKey"))
    }
}
