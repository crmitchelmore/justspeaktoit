import Foundation

/// A provider account that one or more stored credentials unlock.
///
/// The account, not the credential, is the unit a balance belongs to. Deepgram
/// writes one Keychain item that both the transcription card and the voice
/// output card read, and ElevenLabs, Soniox, Cartesia and the rest share a
/// single key across speech-to-text and text-to-speech. Fetching per card
/// would ask the same provider the same question twice and print the same
/// figure twice, so every lookup resolves to an account first and only the
/// account's `primaryCredentialIdentifier` renders the balance.
public struct ProviderBalanceAccount: Sendable, Equatable, Identifiable {
    /// Why an account does or does not show a balance figure.
    public enum Support: Sendable, Equatable {
        /// The provider documents a balance or allowance endpoint this app reads.
        case balance
        /// No readable balance contract: the card offers a billing link instead.
        /// The reason is shown to the user so the omission is explained rather
        /// than silent.
        case billingLinkOnly(reason: String)
    }

    public let id: String
    public let displayName: String
    /// Every Keychain identifier that unlocks this account.
    public let credentialIdentifiers: [String]
    /// The identifier whose settings card owns the balance display.
    public let primaryCredentialIdentifier: String
    public let support: Support
    public let billingURL: URL?

    public init(
        id: String,
        displayName: String,
        credentialIdentifiers: [String],
        primaryCredentialIdentifier: String? = nil,
        support: Support,
        billingURL: String
    ) {
        self.id = id
        self.displayName = displayName
        self.credentialIdentifiers = credentialIdentifiers
        self.primaryCredentialIdentifier = primaryCredentialIdentifier ?? credentialIdentifiers[0]
        self.support = support
        self.billingURL = URL(string: billingURL)
    }
}

/// The canonical account list: which provider accounts exist, which stored
/// credentials belong to each, and whether a balance can honestly be shown.
///
/// The default is a billing link. An account is promoted to `.balance` only
/// where the vendor documents an endpoint that reports what the account holds.
public enum ProviderBalanceDirectory {
    public static let accounts: [ProviderBalanceAccount] = [
        ProviderBalanceAccount(
            id: "deepgram",
            displayName: "Deepgram",
            credentialIdentifiers: ["deepgram.apiKey"],
            support: .balance,
            billingURL: "https://console.deepgram.com/project"
        ),
        ProviderBalanceAccount(
            id: "revai",
            displayName: "Rev.ai",
            credentialIdentifiers: ["revai.apiKey"],
            support: .balance,
            billingURL: "https://www.rev.ai/account"
        ),
        ProviderBalanceAccount(
            id: "elevenlabs",
            displayName: "ElevenLabs",
            credentialIdentifiers: ["elevenlabs.apiKey"],
            support: .balance,
            billingURL: "https://elevenlabs.io/app/subscription"
        ),
        ProviderBalanceAccount(
            id: "openrouter",
            displayName: "OpenRouter",
            credentialIdentifiers: ["openrouter.apiKey"],
            support: .balance,
            billingURL: "https://openrouter.ai/credits"
        ),
        ProviderBalanceAccount(
            id: "openai",
            displayName: "OpenAI",
            // One OpenAI account, two cards: transcription and voice output
            // write separate Keychain items but bill to the same organisation.
            credentialIdentifiers: ["openai.apiKey", "openai.tts.apiKey"],
            primaryCredentialIdentifier: "openai.apiKey",
            support: .billingLinkOnly(
                reason: "OpenAI's admin API reports costs already incurred, not a wallet balance, "
                    + "and it needs an admin key this app does not hold."
            ),
            billingURL: "https://platform.openai.com/settings/organization/billing/overview"
        ),
        ProviderBalanceAccount(
            id: "azure",
            displayName: "Azure",
            credentialIdentifiers: ["azure.speech.apiKey"],
            support: .billingLinkOnly(
                reason: "Azure balances need a separate billing sign-in and an offer eligibility check, "
                    + "which a Speech resource key cannot perform."
            ),
            billingURL: "https://portal.azure.com/#view/Microsoft_Azure_GTM/ModernBillingMenuBlade"
        ),
        ProviderBalanceAccount(
            id: "cartesia",
            displayName: "Cartesia",
            credentialIdentifiers: ["cartesia.apiKey"],
            support: .billingLinkOnly(
                reason: "Cartesia's credits endpoint reports admin usage rather than a spendable wallet, "
                    + "so it is not shown here as a balance."
            ),
            billingURL: "https://play.cartesia.ai/subscription"
        ),
        ProviderBalanceAccount(
            id: "soniox",
            displayName: "Soniox",
            credentialIdentifiers: ["soniox.apiKey"],
            support: .billingLinkOnly(
                reason: "Soniox reports consumed usage rather than a wallet balance."
            ),
            billingURL: "https://console.soniox.com/billing"
        ),
        ProviderBalanceAccount(
            id: "xai",
            displayName: "xAI",
            credentialIdentifiers: ["xai.apiKey"],
            support: .billingLinkOnly(
                reason: "xAI's management billing API needs a separate management key, "
                    + "which an inference key does not provide."
            ),
            billingURL: "https://console.x.ai"
        ),
        ProviderBalanceAccount(
            id: "assemblyai",
            displayName: "AssemblyAI",
            credentialIdentifiers: ["assemblyai.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://www.assemblyai.com/app/account"
        ),
        ProviderBalanceAccount(
            id: "gladia",
            displayName: "Gladia",
            credentialIdentifiers: ["gladia.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://app.gladia.io"
        ),
        ProviderBalanceAccount(
            id: "groq",
            displayName: "Groq",
            credentialIdentifiers: ["groq.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://console.groq.com/settings/billing"
        ),
        ProviderBalanceAccount(
            id: "google",
            displayName: GeminiTranscribeModels.providerDisplayName,
            credentialIdentifiers: ["google.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://aistudio.google.com/app/plan_information"
        ),
        ProviderBalanceAccount(
            id: "mistral",
            displayName: "Mistral",
            credentialIdentifiers: ["mistral.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://console.mistral.ai/billing"
        ),
        ProviderBalanceAccount(
            id: "speechmatics",
            displayName: "Speechmatics",
            credentialIdentifiers: ["speechmatics.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://portal.speechmatics.com"
        ),
        ProviderBalanceAccount(
            id: "meta",
            displayName: "Meta",
            credentialIdentifiers: ["meta.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://llama.developer.meta.com"
        ),
        ProviderBalanceAccount(
            id: "modulate",
            displayName: "Modulate",
            credentialIdentifiers: ["modulate.apiKey"],
            support: .billingLinkOnly(reason: Self.noDocumentedContract),
            billingURL: "https://modulate.ai"
        )
    ]

    private static let noDocumentedContract =
        "This provider publishes no balance endpoint we can read, so Speak links to its billing page instead."

    private static let accountsByCredential: [String: ProviderBalanceAccount] = {
        var mapping: [String: ProviderBalanceAccount] = [:]
        for account in accounts {
            for identifier in account.credentialIdentifiers {
                mapping[identifier] = account
            }
        }
        return mapping
    }()

    public static func account(forCredentialIdentifier identifier: String) -> ProviderBalanceAccount? {
        accountsByCredential[identifier]
    }

    public static func account(id: String) -> ProviderBalanceAccount? {
        accounts.first { $0.id == id }
    }

    /// Whether this credential's card is the one that shows the account's
    /// balance. The deduplication rule lives here so both platforms obey it.
    public static func isPrimaryCredential(_ identifier: String) -> Bool {
        account(forCredentialIdentifier: identifier)?.primaryCredentialIdentifier == identifier
    }
}
