import Foundation

/// Account-discovery capabilities, projected from existing canonical provider metadata
/// and desktop local voice studio backends.
public struct VoiceAccountProvider: Hashable, Identifiable, Sendable {
    private enum Backing: Hashable, Sendable {
        case cloud(LiveTranscriptionProviderID)
        case studio(VoiceStudioKind)
    }

    private let backing: Backing
    public static let xai = Self(.xai)
    public static let mistral = Self(.mistral)
    public static let soniox = Self(.soniox)
    public static let voicebox = Self(studioKind: .voicebox)
    public static let voiceStudio = Self(studioKind: .voiceStudio)
    public static let gptSoVITS = Self(studioKind: .gptSoVITS)
    public static let all = [xai, mistral, soniox]
    public static let studioProviders = [voicebox, voiceStudio, gptSoVITS]
    public static let desktopProviders = all + studioProviders

    public var studioKind: VoiceStudioKind? {
        if case .studio(let kind) = backing { return kind }
        return nil
    }

    public var isStudio: Bool { studioKind != nil }

    public var id: String {
        switch backing {
        case .cloud(let provider): provider.rawValue
        case .studio(let kind): kind.rawValue
        }
    }

    public var displayName: String {
        switch backing {
        case .cloud(let provider): provider.displayName
        case .studio(let kind): kind.displayName
        }
    }

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
        switch backing {
        case .cloud(.soniox): return SonioxTTSCatalog.defaultModel.rawValue
        case .cloud(.mistral): return MistralTTSCatalog.defaultModel.desktopModelIdentifier
        case .cloud: return XAITTSCatalog.providerIdentifier
        case .studio(let kind): return kind.rawValue
        }
    }

    private init(_ provider: LiveTranscriptionProviderID) { self.backing = .cloud(provider) }

    public init(studioKind: VoiceStudioKind) { self.backing = .studio(studioKind) }

    public init(id: String) throws {
        guard let value = Self.desktopProviders.first(where: { $0.id == id }) else {
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
