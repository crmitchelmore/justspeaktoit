import XCTest

@testable import SpeakCore

final class BatchTranscriptionRoutingTests: XCTestCase {
    func testCatalogueRowsKeepExplicitPlatformCapabilityDifferences() throws {
        let iosDirect = Set(["openai", "cartesia", "gladia", "azure", "alibaba", "meta", "google", "xai"])
            .union(FileSpeechProvider.allCases.map(\.rawValue))
        let macOnly: Set<String> = [
            "assemblyai", "deepgram", "elevenlabs", "groq", "mistral", "modulate", "revai", "soniox", "speechmatics"
        ]
        for model in ModelCatalog.batchTranscription {
            let mac = try XCTUnwrap(BatchTranscriptionRouting.route(for: model.id, platform: .macOS))
            let ios = try XCTUnwrap(BatchTranscriptionRouting.route(for: model.id, platform: .iOS))
            switch ModelCredentialResolver.requirement(for: model.id, purpose: .batchTranscription) {
            case .notRequired:
                XCTAssertEqual(mac.transport, .appleLocal, model.id)
                XCTAssertEqual(ios, mac, model.id)
            case .apiKey(let identifier, _):
                XCTAssertEqual(mac.apiKeyIdentifier, identifier, model.id)
                if identifier == "openrouter.apiKey" {
                    XCTAssertEqual(mac.transport, .openRouter, model.id)
                    XCTAssertEqual(ios, mac, model.id)
                } else if iosDirect.contains(mac.providerID) {
                    XCTAssertEqual(mac.transport, .directProvider, model.id)
                    XCTAssertEqual(ios, mac, model.id)
                } else {
                    XCTAssertTrue(macOnly.contains(mac.providerID), "Classify the new platform capability: " + model.id)
                    XCTAssertEqual(mac.transport, .directProvider, model.id)
                    XCTAssertEqual(ios.transport, .openRouter, model.id)
                    XCTAssertEqual(ios.apiKeyIdentifier, "openrouter.apiKey", model.id)
                    XCTAssertEqual(ios.apiModelName, model.id)
                }
            }
        }
    }

    func testDirectAndOpenRouterModelsKeepTheirDifferentOwnersAndModelNames() throws {
        let cases: [String: ExpectedProjection] = [
            "openai/whisper-1": .init(provider: "openai", apiModel: "whisper-1"),
            OpenAITranscriptionModels.gptTranscribeCatalogID: .init(provider: "openai", apiModel: "gpt-transcribe"),
            GeminiTranscribeModels.batchCatalogID: .init(
                provider: "google", apiModel: GeminiTranscribeModels.batchAPIName
            ),
            "openai/gpt-audio": .init(provider: "openrouter", apiModel: "openai/gpt-audio"),
            "google/gemini-3.1-flash-lite": .init(provider: "openrouter", apiModel: "google/gemini-3.1-flash-lite"),
            "openrouter/transcription/openai/gpt-transcribe": .init(
                provider: "openrouter", apiModel: "openai/gpt-transcribe"
            ),
            "openrouter/transcription/google/model/version": .init(
                provider: "openrouter", apiModel: "google/model/version"
            )
        ]
        for platform in [BatchTranscriptionPlatform.macOS, .iOS] {
            for (model, expected) in cases {
                let route = try XCTUnwrap(BatchTranscriptionRouting.route(
                    for: " \n" + model + "\t", platform: platform
                ))
                XCTAssertEqual(route.modelID, model)
                XCTAssertEqual(route.providerID, expected.provider)
                XCTAssertEqual(
                    route.apiKeyIdentifier, ProviderCredentialCatalogue.apiKeyIdentifier(for: expected.provider)
                )
                XCTAssertEqual(route.apiModelName, expected.apiModel)
                XCTAssertEqual(route.transport, expected.provider == "openrouter" ? .openRouter : .directProvider)
            }
        }
    }

    private struct ExpectedProjection {
        let provider: String
        let apiModel: String?
    }

    func testKnownMacOnlyBatchModelsDoNotBecomeDirectIOSCapabilities() throws {
        let cases = [
            ("elevenlabs/scribe_v2", "elevenlabs"),
            ("groq/whisper-large-v3-turbo", "groq"),
            ("deepgram/nova-3", "deepgram"),
            ("soniox/stt-async-v5", "soniox"),
            ("revai/default", "revai")
        ]
        for (model, provider) in cases {
            let mac = try XCTUnwrap(BatchTranscriptionRouting.route(for: model, platform: .macOS))
            XCTAssertEqual(mac.providerID, provider)
            XCTAssertEqual(mac.transport, .directProvider)
            let ios = try XCTUnwrap(BatchTranscriptionRouting.route(for: model, platform: .iOS))
            XCTAssertEqual(ios.providerID, "openrouter")
            XCTAssertEqual(ios.transport, .openRouter)
            XCTAssertEqual(ios.apiKeyIdentifier, "openrouter.apiKey")
            XCTAssertEqual(ios.apiModelName, model)
        }
    }

    func testUnknownCaseAndMalformedInputsRetainCompatibilityWithoutClaimingSupport() throws {
        for model in ["", "OpenAI/whisper-1", "unknown/model", "openai/not-a-model",
                      "local/downloaded/model", "openai/gpt-live-transcribe-streaming"] {
            XCTAssertNil(BatchTranscriptionRouting.route(for: model, platform: .macOS), model)
            let ios = try XCTUnwrap(BatchTranscriptionRouting.route(for: model, platform: .iOS))
            XCTAssertEqual(ios.transport, .openRouter, model)
            XCTAssertEqual(ios.modelID, model)
        }
        let invalidWrapped = "openrouter/transcription/openai/"
        for platform in [BatchTranscriptionPlatform.macOS, .iOS] {
            let route = try XCTUnwrap(BatchTranscriptionRouting.route(for: invalidWrapped, platform: platform))
            XCTAssertEqual(route.transport, .openRouter)
            XCTAssertNil(route.apiModelName, "The existing client must reject the malformed downstream identifier")
        }
        let alibaba = try XCTUnwrap(BatchTranscriptionRouting.route(for: "alibaba/unknown", platform: .iOS))
        XCTAssertEqual(alibaba.providerID, "alibaba", "Its client retains invalid-selection refusal ownership")
        XCTAssertNil(BatchTranscriptionRouting.route(for: "alibaba/unknown", platform: .macOS))
    }

    func testNativeAndProviderManagedModelsDoNotInventAWireModelName() throws {
        for platform in [BatchTranscriptionPlatform.macOS, .iOS] {
            let local = try XCTUnwrap(BatchTranscriptionRouting.route(
                for: AppleLocalModels.speechTranscriberModelID, platform: platform
            ))
            XCTAssertEqual(local.transport, .appleLocal)
            XCTAssertEqual(local.providerID, "apple")
            XCTAssertNil(local.apiKeyIdentifier)
            XCTAssertNil(local.apiModelName)
        }
        for model in ["revai/default", AssemblyAIModels.universal35ProBatchID,
                      AzureTranscriptionModels.mai2, FileSpeechProvider.reson8.modelID] {
            let route = try XCTUnwrap(BatchTranscriptionRouting.route(for: model, platform: .macOS))
            XCTAssertEqual(route.transport, .directProvider)
            XCTAssertNil(route.apiModelName, "Provider-managed request fields must stay in the client: " + model)
        }
    }
}
