import Foundation
import XCTest

@testable import SpeakCore

final class CloudSharingConsentTests: XCTestCase {
    private func inputs(
        batch: Bool = false,
        live: String = "deepgram/nova-3-streaming",
        batchModel: String = "local/whisper-base",
        postProcessing: Bool = true,
        postProcessingModel: String = ModelCatalog.defaultPostProcessingModel,
        voiceOutput: Bool = false,
        voiceProvider: VoiceOutputProvider = .openrouter
    ) -> PrivacyWorkflowInputs {
        PrivacyWorkflowInputs(
            usesBatchTranscription: batch,
            liveTranscriptionModelID: live,
            batchTranscriptionModelID: batchModel,
            postProcessingEnabled: postProcessing,
            postProcessingModelID: postProcessingModel,
            voiceOutputEnabled: voiceOutput,
            voiceOutputProvider: voiceProvider
        )
    }

    private func requests(_ inputs: PrivacyWorkflowInputs) -> [CloudSharingRequest] {
        CloudSharingConsent.requests(for: PrivacyWorkflowSummary.make(inputs))
    }

    func testRequests_namePerProviderDataKindsFromTheWorkflow() {
        let derived = requests(inputs(voiceOutput: true))

        XCTAssertEqual(derived.map(\.provider.id), ["deepgram", "openrouter"])
        XCTAssertEqual(derived.first?.kinds, [.audio])
        XCTAssertEqual(derived.last?.kinds, [.transcriptText, .textToSpeak])
    }

    func testRequests_followTheActiveRecipients() {
        for configuration in [
            inputs(), inputs(voiceOutput: true), inputs(postProcessing: false),
            inputs(batch: true, batchModel: "deepgram/nova-3"), inputs(live: AppleLocalModels.speechTranscriberModelID)
        ] {
            let summary = PrivacyWorkflowSummary.make(configuration)
            let names = Set(CloudSharingConsent.requests(for: summary).map(\.provider.displayName))
            let recipients = Set(summary.activeRecipients).subtracting(["Apple"])
            XCTAssertEqual(names.count, recipients.count, "\(summary.activeRecipients)")
        }
    }

    func testRequests_areEmptyWhenEverythingRunsOnDevice() {
        XCTAssertEqual(requests(inputs(batch: true, postProcessing: false)), [])
    }

    func testRequests_exemptTheAppleSpeechFallback() {
        let derived = requests(inputs(live: AppleLocalModels.speechTranscriberModelID, postProcessing: false))
        XCTAssertEqual(derived, [], "The system Speech Recognition permission covers the Apple fallback")
    }

    func testMissing_dropsAllowedKindsAndKeepsTheRest() {
        var consent = CloudSharingConsent()
        let derived = requests(inputs(voiceOutput: true))
        XCTAssertEqual(consent.missing(derived), derived)

        consent.grant([CloudSharingRequest(provider: derived[1].provider, kinds: [.transcriptText])])
        let missing = consent.missing(derived)
        XCTAssertEqual(missing.map(\.provider.id), ["deepgram", "openrouter"])
        XCTAssertEqual(missing.last?.kinds, [.textToSpeak], "Allowing clean-up does not allow speech")

        consent.grant(missing)
        XCTAssertEqual(consent.missing(derived), [])
    }

    func testChangingProvider_asksAgain() {
        var consent = CloudSharingConsent()
        consent.grant(requests(inputs()))
        XCTAssertEqual(consent.missing(requests(inputs())), [])

        let switched = consent.missing(requests(inputs(live: "assemblyai/universal-3-6-pro")))
        XCTAssertEqual(switched.map(\.provider.id), ["assemblyai"])
    }

    func testWithdraw_removesOneProviderOrAll() {
        var consent = CloudSharingConsent()
        consent.grant(requests(inputs(voiceOutput: true)))
        consent.withdraw(providerID: "deepgram")
        XCTAssertEqual(consent.allowedRequests.map(\.provider.id), ["openrouter"])
        consent.withdrawAll()
        XCTAssertEqual(consent.allowedRequests, [])
    }

    func testStore_persistsJSONAndNotifies() throws {
        let suite = "CloudSharingConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        let store = CloudSharingConsentStore(defaults: defaults, notificationCenter: center)
        let notified = expectation(forNotification: CloudSharingConsentStore.didChangeNotification, object: store,
                                   notificationCenter: center)

        store.grant(requests(inputs(voiceOutput: true)))
        wait(for: [notified], timeout: 1)

        XCTAssertEqual(
            defaults.string(forKey: CloudSharingConsentStore.defaultsKey),
            #"{"grants":{"deepgram":["audio"],"openrouter":["transcriptText","textToSpeak"]},"version":1}"#,
            "Android reads this exact format"
        )
        XCTAssertEqual(CloudSharingConsentStore(defaults: defaults).consent, store.consent)
    }

    func testStore_treatsUnreadableJSONAsNoConsent() throws {
        let suite = "CloudSharingConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not json", forKey: CloudSharingConsentStore.defaultsKey)
        XCTAssertEqual(CloudSharingConsentStore(defaults: defaults).consent, CloudSharingConsent())
    }

    func testProviderID_comesFromTheCredentialIdentifier() {
        XCTAssertEqual(CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: "openai.tts.apiKey"), "openai")
        XCTAssertEqual(
            CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: "azure.speech.apiKey"), "azure"
        )
        XCTAssertEqual(CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: "deepgram.apiKey"), "deepgram")
    }

    func testEveryCloudProvider_hasAPrivacyPolicy() {
        var providerIDs = Set(ModelCredentialResolver.allKnownAPIKeyIdentifiers.map {
            CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: $0)
        })
        let models: [(String, ModelCredentialPurpose)] =
            ModelCatalog.liveTranscription.map { ($0.id, .liveTranscription) }
            + ModelCatalog.batchTranscription.map { ($0.id, .batchTranscription) }
            + ModelCatalog.postProcessing.map { ($0.id, .postProcessing) }
        for (id, purpose) in models {
            if let request = CloudSharingConsent.request(forModel: id, purpose: purpose) {
                providerIDs.insert(request.provider.id)
            }
        }
        providerIDs.formUnion(VoiceOutputProvider.allCases.map {
            CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: $0.apiKeyIdentifier)
        })

        for id in providerIDs.sorted() {
            let provider = CloudSharingProviderCatalogue.provider(id: id)
            XCTAssertNotNil(provider?.privacyPolicyURL, "Add \(id) to CloudSharingProviderCatalogue")
            XCTAssertEqual(provider?.privacyPolicyURL?.scheme, "https", id)
        }
        XCTAssertEqual(
            Set(CloudSharingProviderCatalogue.all.map(\.id)).count, CloudSharingProviderCatalogue.all.count,
            "Provider IDs are unique"
        )
    }

    func testRequestForModel_isNilOnDevice() {
        XCTAssertNil(CloudSharingConsent.request(forModel: "local/whisper-base", purpose: .batchTranscription))
        XCTAssertEqual(
            CloudSharingConsent.request(forModel: "deepgram/nova-3", purpose: .batchTranscription)?.kinds, [.audio]
        )
    }

    func testBlockedMessage_namesTheProviders() {
        let message = CloudSharingConsent.blockedMessage(for: requests(inputs()))
        XCTAssertTrue(message.contains("Deepgram and OpenRouter"), message)
    }
}
