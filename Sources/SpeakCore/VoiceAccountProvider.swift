import Foundation

/// Account-discovery capabilities, projected from existing canonical provider metadata.
public struct VoiceAccountProvider: Hashable, Identifiable, Sendable {
    private let provider: LiveTranscriptionProviderID
    public static let xai = Self(.xai)
    public static let mistral = Self(.mistral)
    public static let soniox = Self(.soniox)
    public static let all = [xai, mistral, soniox]

    public var id: String { provider.rawValue }
    public var displayName: String { provider.displayName }
    public var hasDocumentedPresets: Bool { !documentedPresets.isEmpty }
    public var documentedPresets: [DesktopSpeechVoice] {
        if self == .xai { return XAITTSCatalog.voices.map(DesktopSpeechVoice.xai) }
        if self == .soniox {
            return SonioxTTSCatalog.voices.map {
                .soniox(SonioxTTSCatalog.resolvedVoice(voiceID: $0.providerVoiceID, accountVoices: []))
            }
        }
        return []
    }

    public var modelIdentifier: String {
        if self == .soniox { return SonioxTTSCatalog.defaultModel.rawValue }
        if self == .mistral { return MistralTTSCatalog.defaultModel.desktopModelIdentifier }
        return XAITTSCatalog.providerIdentifier
    }

    private init(_ provider: LiveTranscriptionProviderID) { self.provider = provider }

    public init(id: String) throws {
        guard let value = Self.all.first(where: { $0.id == id }) else {
            throw VoiceOutputCredentialError.unavailable
        }
        self = value
    }
}

public struct VoiceAccountCredentialContext: Equatable, Sendable {
    public let provider: VoiceAccountProvider
    public let sessionID: UUID
    public let epoch: UUID

    public init(provider: VoiceAccountProvider, sessionID: UUID, epoch: UUID) {
        self.provider = provider
        self.sessionID = sessionID
        self.epoch = epoch
    }
}

public enum VoiceOutputCredentialDestination: Equatable, Sendable {
    case selectedVoice(selectionEpoch: UUID)
    case explicitProvider(VoiceAccountCredentialContext)
}
