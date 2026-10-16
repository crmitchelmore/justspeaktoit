import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MistralAccountVoiceInventory: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumVoices = 512
    public static let maximumPageBytes = 524_288
    public let voices: [MistralTTSVoice]
    public let context: VoiceAccountCredentialContext
    private let credential: String
    public var description: String { "Mistral account inventory (\(voices.count) voices)" }
    public var debugDescription: String { description }
    public var desktopVoices: [DesktopSpeechVoice] { voices.map(DesktopSpeechVoice.mistral) }

    public func matchesCredential(_ value: String) -> Bool {
        credential == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func voice(forID identifier: String) -> MistralTTSVoice? {
        voices.first { $0.providerVoiceID.lowercased() == identifier.lowercased() }
    }

    public static func fetch(
        session: URLSession = .shared, context: VoiceAccountCredentialContext? = nil,
        credential: @Sendable () async throws -> String
    ) async throws -> Self {
        try Task.checkCancellation()
        let context = context ?? .init(provider: .mistral, sessionID: UUID(), epoch: UUID())
        guard context.provider == .mistral else { throw VoiceAccountDiscoveryError.invalidInventory(.mistral) }
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw VoiceAccountDiscoveryError.missingCredential(.mistral) }
        var voices: [MistralTTSVoice] = [], identifiers = Set<String>()
        for page in 0..<MistralTTSAPI.maxVoicePages {
            let data = try await receive(session: session, key: key, offset: page * MistralTTSAPI.voicePageSize)
            try Task.checkCancellation()
            let entries: [MistralTTSVoice]
            do { entries = try MistralTTSAPI.decodeVoices(from: data) } catch {
                throw VoiceAccountDiscoveryError.invalidInventory(.mistral)
            }
            guard entries.count <= MistralTTSAPI.voicePageSize,
                  entries.count <= maximumVoices - voices.count else {
                throw VoiceAccountDiscoveryError.oversized(.mistral)
            }
            for voice in entries {
                guard valid(voice), identifiers.insert(voice.id.lowercased()).inserted else {
                    throw VoiceAccountDiscoveryError.invalidInventory(.mistral)
                }
                voices.append(voice)
            }
            if entries.count < MistralTTSAPI.voicePageSize {
                return Self(voices: voices, context: context, credential: key)
            }
        }
        throw VoiceAccountDiscoveryError.oversized(.mistral)
    }

    private static func receive(session: URLSession, key: String, offset: Int) async throws -> Data {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                MistralTTSAPI.voiceListRequest(apiKey: key, offset: offset), session: session,
                limit: maximumPageBytes, deadline: .seconds(20)
            ) { response in
                guard (200..<300).contains(response.statusCode) else {
                    throw VoiceAccountDiscoveryError.service(.mistral, response.statusCode)
                }
            }.body
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? VoiceAccountDiscoveryError { throw failure }
            switch error as? OpenRouterBoundedResponseTransport.Failure {
            case .responseTooLarge: throw VoiceAccountDiscoveryError.oversized(.mistral)
            case .timedOut: throw VoiceAccountDiscoveryError.timedOut(.mistral)
            case .invalidResponse: throw VoiceAccountDiscoveryError.invalidInventory(.mistral)
            case nil:
                throw (error as? URLError)?.code == .timedOut
                    ? VoiceAccountDiscoveryError.timedOut(.mistral) : VoiceAccountDiscoveryError.transport(.mistral)
            }
        }
    }

    private static func valid(_ voice: MistralTTSVoice) -> Bool {
        voice.id.utf8.count == 36 && UUID(uuidString: voice.id) != nil
            && validText(voice.name, maximum: 256) && !voice.name.isEmpty
            && [voice.slug, voice.gender].compactMap { $0 }.allSatisfy { validText($0, maximum: 128) }
            && (voice.description.map { validText($0, maximum: 4_096) } ?? true)
            && (voice.languages?.count ?? 0) <= 64
            && (voice.languages?.allSatisfy { validText($0, maximum: 32) && !$0.isEmpty } ?? true)
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public enum VoiceAccountDiscoveryError: LocalizedError, Equatable, Sendable {
    case missingCredential(VoiceAccountProvider), service(VoiceAccountProvider, Int)
    case invalidInventory(VoiceAccountProvider), oversized(VoiceAccountProvider)
    case timedOut(VoiceAccountProvider), transport(VoiceAccountProvider), credentialChanged(VoiceAccountProvider)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            "Enter the \(provider.displayName) Voice key before explicitly refreshing account voices."
        case .service(let provider, let status):
            "\(provider.displayName) account listing failed (HTTP \(status)). No new listing was accepted."
        case .invalidInventory(let provider):
            "\(provider.displayName) returned an invalid account listing. No new listing was accepted."
        case .oversized(let provider):
            "The \(provider.displayName) account listing exceeds this host's bounded inventory limit."
        case .timedOut(let provider):
            "The \(provider.displayName) account listing did not finish within its discovery budget."
        case .transport(let provider):
            "The \(provider.displayName) account listing could not be received. Try Refresh again."
        case .credentialChanged(let provider):
            "The \(provider.displayName) key changed. Explicitly refresh voices for the current key before using them."
        }
    }
}
