import XCTest
@testable import SpeakCore

final class CloudSharingConsentTests: XCTestCase {
    func testGrantIsPerKindAndWithdrawClearsTheProvider() {
        let audio = request("deepgram", .audio, .liveTranscription)
        let speech = request("deepgram", .textToSpeak, .voiceOutput)
        var consent = CloudSharingConsent()
        XCTAssertFalse(consent.allows(audio))
        consent = consent.granting(audio)
        XCTAssertTrue(consent.allows(audio))
        XCTAssertFalse(consent.allows(speech), "Audio permission is not permission to send text")
        consent = consent.granting(speech)
        XCTAssertEqual(consent.grantedKinds(for: "deepgram"), [.audio, .textToSpeak])
        consent = consent.withdrawing(providerID: "deepgram")
        XCTAssertFalse(consent.allows(audio))
        XCTAssertFalse(consent.allows(speech))
        XCTAssertTrue(consent.grantedProviders.isEmpty)
    }

    func testJSONRoundTripKeepsOnlyKnownKindsAndFailsClosed() {
        let consent = CloudSharingConsent().granting(request("openrouter", .transcript, .postProcessing))
        let decoded = CloudSharingConsent(json: consent.encodedJSON())
        XCTAssertEqual(decoded, consent)
        XCTAssertTrue(consent.encodedJSONString().contains("\"version\":1"))
        XCTAssertTrue(consent.encodedJSONString().contains("\"transcript\""))

        let unknown = Data("{\"grants\":{\"deepgram\":[\"audio\",\"nope\"]},\"version\":1}".utf8)
        XCTAssertTrue(CloudSharingConsent(json: unknown).allows(providerID: "deepgram", kind: .audio))
        XCTAssertFalse(CloudSharingConsent(json: unknown).allows(providerID: "deepgram", kind: .transcript))

        XCTAssertTrue(CloudSharingConsent(json: Data("not json".utf8)).grantedProviders.isEmpty)
        XCTAssertTrue(CloudSharingConsent(json: Data("{\"grants\":{},\"version\":2}".utf8)).grantedProviders.isEmpty)
    }

    func testStoreIsDeviceLocalAndNotASyncKey() {
        let suite = "CloudSharingConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = CloudSharingConsentStore(defaults: defaults, notificationCenter: NotificationCenter())
        XCTAssertFalse(store.allows(request("openai", .audio, .batchTranscription)))
        store.grant(request("openai", .audio, .batchTranscription))
        XCTAssertTrue(store.consent.allows(providerID: "openai", kind: .audio))
        XCTAssertFalse(DesktopConfiguration.editorProjectionKeys.contains(CloudSharingConsent.storageKey))
        XCTAssertNotEqual(CloudSharingConsent.storageKey, "diagnosticsConsent")
    }

    func testRequestsFollowThePrivacySummary() {
        let inputs = PrivacyWorkflowInputs(
            usesBatchTranscription: false,
            liveTranscriptionModelID: "deepgram/nova-3-streaming",
            batchTranscriptionModelID: "deepgram/nova-3",
            postProcessingEnabled: true,
            postProcessingModelID: "openai/gpt-6-luna",
            voiceOutputEnabled: true,
            voiceOutputProvider: .deepgram
        )
        let summary = PrivacyWorkflowSummary.make(inputs)
        let requests = CloudSharingConsent.requests(for: inputs, availability: .apple)
        XCTAssertEqual(requests.map(\.provider.displayName), ["Deepgram", "OpenRouter", "Deepgram"])
        XCTAssertEqual(requests.map(\.kinds), [[.audio], [.transcript], [.textToSpeak]])
        XCTAssertEqual(Set(requests.map(\.provider.displayName)), Set(summary.activeRecipients))
        XCTAssertTrue(requests.allSatisfy(\.canUseOnDevice))

        let onDevice = PrivacyWorkflowInputs(
            usesBatchTranscription: false,
            liveTranscriptionModelID: AppleLocalModels.preferredSpeechModelID,
            batchTranscriptionModelID: AppleLocalModels.preferredSpeechModelID,
            postProcessingEnabled: false,
            postProcessingModelID: "local/post-processing/rules",
            voiceOutputEnabled: false,
            voiceOutputProvider: .deepgram
        )
        var strict = onDevice
        strict.appleSpeechRequiresOnDeviceRecognition = true
        strict.appleSpeechAnalyzerFallbackAllowed = false
        XCTAssertTrue(CloudSharingConsent.requests(for: strict, availability: .apple).isEmpty)
    }

    func testAppleFallbackAndLegacyBatchAreCloudSends() {
        let live = CloudSharingConsent.request(
            forModel: AppleLocalModels.speechTranscriberModelID,
            purpose: .liveTranscription,
            appleSpeechMayUseAppleServers: true
        )
        XCTAssertEqual(live?.provider.id, "apple")
        XCTAssertEqual(live?.kinds, [.audio])
        XCTAssertNil(CloudSharingConsent.request(
            forModel: AppleLocalModels.speechTranscriberModelID, purpose: .liveTranscription
        ))

        let legacy = CloudSharingConsent.request(
            forModel: AppleLocalModels.legacySpeechModelID, purpose: .batchTranscription
        )
        XCTAssertEqual(legacy?.provider.id, "openrouter")
    }

    func testBlockedMessageNamesTheProviderAndTheData() {
        let message = CloudSharingConsent.blockedMessage(for: request("deepgram", .audio, .liveTranscription))
        XCTAssertEqual(
            message,
            "Nothing was sent to Deepgram. Open Just Speak to It and allow your audio to be sent to Deepgram, "
                + "or choose an on-device option."
        )
        XCTAssertFalse(message.contains("api"))
    }

    func testCatalogueCoversRoutedProvidersAndExportsPrivacyURLs() throws {
        var missing: [String] = []
        for provider in LiveTranscriptionProviderID.allCases where provider != .apple {
            if CloudSharingProviderCatalogue.provider(id: provider.rawValue) == nil {
                missing.append(provider.rawValue)
            } else {
                let name = CloudSharingProviderCatalogue.provider(id: provider.rawValue)?.displayName
                if name != provider.displayName { missing.append("name \(provider.rawValue)") }
            }
        }
        for provider in FileSpeechProvider.allCases
        where CloudSharingProviderCatalogue.provider(id: provider.rawValue) == nil {
            missing.append(provider.rawValue)
        }
        for provider in NativeTextModels.providers
        where CloudSharingProviderCatalogue.provider(id: provider.id) == nil {
            missing.append(provider.id)
        }
        XCTAssertTrue(missing.isEmpty, "\(missing)")
        for provider in CloudSharingProviderCatalogue.all {
            XCTAssertEqual(provider.privacyPolicyURL.scheme, "https", provider.id)
        }
        let asset = try CloudSharingProviderCatalogue.androidJSON()
        let decoded = try JSONDecoder().decode(Export.self, from: asset)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.providers.map(\.id), CloudSharingProviderCatalogue.all.map(\.id))
    }

    func testAndroidAssetMatchesTheCatalogue() throws {
        let expected = try CloudSharingProviderCatalogue.androidJSON()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/cloud_sharing_providers.json")
        let committed = try Data(contentsOf: url)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/cloud_sharing_providers.json is stale"
        )
    }

    private func request(
        _ id: String, _ kind: CloudSharedDataKind, _ purpose: ModelCredentialPurpose
    ) -> CloudSharingRequest {
        CloudSharingConsent.request(
            providerID: id, kind: kind, purpose: purpose, canUseOnDevice: true
        )!
    }

    private struct Export: Decodable {
        struct Row: Decodable { let id: String }
        let providers: [Row]
        let version: Int
    }
}
