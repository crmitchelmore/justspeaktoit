import XCTest
@testable import SpeakApp
@testable import SpeakCore

final class AlibabaProviderRoutingTests: XCTestCase {
    func testRegistry_ClaimsInvalidAlibabaSelectionsRatherThanOpenRouter() async throws {
        let registry = TranscriptionProviderRegistry.shared
        for model in AlibabaSpeechModels.batchIDs + ["alibaba/unknown", AlibabaSpeechModels.funLive] {
            let provider = await registry.provider(forModel: " \(model) ")
            XCTAssertTrue(provider is AlibabaTranscriptionProvider)
        }
    }

    func testLocalValidation_RejectsUnboundKeysAndAcceptsBoundCredentialsWithoutNetwork() async throws {
        let provider = AlibabaTranscriptionProvider()
        let invalid = await provider.validateAPIKey("bare-key")
        guard case .failure = invalid.outcome else { return XCTFail("A bare Alibaba key was accepted") }
        let credential = try AlibabaSpeechConfiguration(
            region: .singapore, workspace: "llm-example", apiKey: "synthetic"
        ).encodedCredentials()
        let valid = await provider.validateAPIKey(credential)
        guard case .success(let message) = valid.outcome else { return XCTFail("Valid configuration was rejected") }
        XCTAssertTrue(message.contains("locally"))
    }
}
