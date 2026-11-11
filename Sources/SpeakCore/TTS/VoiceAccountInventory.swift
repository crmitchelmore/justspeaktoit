import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ephemeral, credential-bound account evidence, never a saved provider catalogue.
public enum VoiceAccountInventory: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case xai(XAIAccountVoiceInventory)
    case mistral(MistralAccountVoiceInventory)
    case soniox(SonioxAccountVoiceInventory)
    public var description: String { "\(provider.displayName) account inventory (\(desktopVoices.count) voices)" }
    public var debugDescription: String { description }

    public var provider: VoiceAccountProvider {
        switch self {
        case .xai: .xai
        case .mistral: .mistral
        case .soniox: .soniox
        }
    }

    public var desktopVoices: [DesktopSpeechVoice] {
        switch self {
        case .xai(let inventory): inventory.desktopVoices
        case .mistral(let inventory): inventory.desktopVoices
        case .soniox(let inventory): inventory.desktopVoices
        }
    }

    public var xai: XAIAccountVoiceInventory? {
        if case .xai(let inventory) = self { return inventory }
        return nil
    }

    public var mistral: MistralAccountVoiceInventory? {
        if case .mistral(let inventory) = self { return inventory }
        return nil
    }

    public var soniox: SonioxAccountVoiceInventory? {
        if case .soniox(let inventory) = self { return inventory }
        return nil
    }

    public func contains(_ voice: DesktopSpeechVoice) -> Bool { desktopVoices.contains(voice) }

    public func matchesCredential(_ value: String) -> Bool {
        switch self {
        case .xai(let inventory): inventory.matchesCredential(value)
        case .mistral(let inventory): inventory.matchesCredential(value)
        case .soniox(let inventory): inventory.matchesCredential(value)
        }
    }

    public static func fetch(
        provider: VoiceAccountProvider, session: URLSession = .shared,
        context: VoiceAccountCredentialContext? = nil, sonioxRegion: SonioxTTSRegion = .unitedStates,
        credential: @Sendable () async throws -> String
    ) async throws -> Self {
        guard context == nil || context?.provider == provider else {
            throw VoiceAccountDiscoveryError.invalidInventory(provider)
        }
        switch provider {
        case .xai: return try await .xai(.fetch(session: session, credential: credential))
        case .mistral: return try await .mistral(.fetch(session: session, context: context, credential: credential))
        case .soniox:
            return try await .soniox(.fetch(
                session: session, region: sonioxRegion, context: context, credential: credential))
        default: throw VoiceOutputCredentialError.unavailable
        }
    }
}
