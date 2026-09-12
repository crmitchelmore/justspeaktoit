import SpeakCore
import XCTest

@testable import SpeakApp

/// The settings surface shows one balance per account, not one per card. These
/// tests pin that mapping to the app's own credential catalogues so a provider
/// added later cannot quietly appear twice or with no billing route at all.
final class ProviderBalanceSettingsTests: XCTestCase {
    func testEveryTTSCredentialResolvesToABalanceAccount() {
        for provider in TTSProvider.allCases where provider.requiresAPIKey {
            XCTAssertNotNil(
                ProviderBalanceDirectory.account(forCredentialIdentifier: provider.apiKeyIdentifier),
                "\(provider.displayName) has no balance account or billing link"
            )
        }
    }

    func testASharedAccountKeyShowsItsBalanceOnASingleCard() {
        // Providers whose one key powers transcription and voice output render a
        // single combined card, so their credential is the account's primary.
        for provider in TTSProvider.allCases
        where provider.requiresAPIKey && provider.sharesTranscriptionCredential {
            XCTAssertTrue(
                ProviderBalanceDirectory.isPrimaryCredential(provider.apiKeyIdentifier),
                "\(provider.displayName)'s shared key should own its account's balance"
            )
        }
    }

    func testDeepgramShowsOneBalanceAcrossItsTranscriptionAndVoiceCards() {
        // Deepgram keeps separate transcription and voice-output cards but both
        // read the same Keychain item, so exactly one account backs them.
        let transcription = "deepgram.apiKey"
        let voiceOutput = TTSProvider.deepgram.apiKeyIdentifier

        XCTAssertEqual(voiceOutput, transcription)
        XCTAssertEqual(
            ProviderBalanceDirectory.account(forCredentialIdentifier: transcription)?.id,
            ProviderBalanceDirectory.account(forCredentialIdentifier: voiceOutput)?.id
        )
        XCTAssertEqual(
            ProviderBalanceDirectory.accounts.filter { $0.credentialIdentifiers.contains(transcription) }.count,
            1
        )
    }

    func testOpenAIVoiceOutputCardDoesNotRepeatTheAccountBalance() {
        XCTAssertEqual(
            ProviderBalanceDirectory.account(forCredentialIdentifier: TTSProvider.openai.apiKeyIdentifier)?.id,
            "openai"
        )
        XCTAssertFalse(ProviderBalanceDirectory.isPrimaryCredential(TTSProvider.openai.apiKeyIdentifier))
    }

    func testAzureOffersABillingLinkRatherThanABalance() {
        guard let azure = ProviderBalanceDirectory.account(
            forCredentialIdentifier: TTSProvider.azure.apiKeyIdentifier
        ) else {
            return XCTFail("Azure has no balance account entry")
        }
        guard case .billingLinkOnly(let reason) = azure.support else {
            return XCTFail("Azure must not claim a readable balance")
        }
        XCTAssertTrue(reason.lowercased().contains("billing"), reason)
        XCTAssertNotNil(azure.billingURL)
    }

    @MainActor
    func testABalanceFailureLeavesTheAccountReadableAndUnspendable() async {
        let store = ProviderBalanceStore(sources: [FailingBalanceSource()])
        store.configure { _ in "key" }

        store.refresh(accountID: "deepgram")
        for _ in 0..<200 where store.entries["deepgram"] == .refreshing || store.entries["deepgram"] == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard case .loaded(let snapshot) = store.entries["deepgram"] else {
            let entry = String(describing: store.entries["deepgram"])
            return XCTFail("A failed fetch must still produce a state, got \(entry)")
        }
        XCTAssertFalse(snapshot.state.isSpendableCredit)
    }
}

private struct FailingBalanceSource: ProviderBalanceSource {
    let accountID = "deepgram"

    func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            accountID: accountID,
            providerDisplayName: "Deepgram",
            state: .unknown(reason: "The billing endpoint replied HTTP 500."),
            refreshedAt: Date()
        )
    }
}
