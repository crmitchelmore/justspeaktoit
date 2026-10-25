import Foundation

/// Persisted credential identities shared by provider adapters and both Apple apps.
/// Adding a provider does not opt its credential into cross-device transfer.
public enum ProviderCredentialCatalogue {
    /// Preserve historical bytes, including Azure's voice/transcription shared item.
    /// Unknown provider IDs retain the existing extensible `<id>.apiKey` convention.
    public static func apiKeyIdentifier(for providerID: String) -> String {
        if providerID == "azure" { return AzureSpeechConfiguration.credentialIdentifier }
        return "\(providerID).apiKey"
    }

    /// Project the existing canonical model/operation routing, including
    /// file-only providers and dedicated voice-output slots, without another
    /// independently maintained provider list.
    public static let all = ModelCredentialResolver.allKnownAPIKeyIdentifiers.sorted()

    /// The existing encrypted-sync policy, deliberately narrower than `all`.
    /// Expanding this list changes which secrets leave a device and requires a
    /// separately reviewed policy change; catalogue additions never expand it.
    public static let cloudKitSyncable: Set<String> = Set([
        "alibaba", "deepgram", "openai", "openrouter", "elevenlabs", "cartesia",
        "assemblyai", "gladia", "google", "modulate", "soniox", "xai", "meta"
    ].map { apiKeyIdentifier(for: $0) })
}
