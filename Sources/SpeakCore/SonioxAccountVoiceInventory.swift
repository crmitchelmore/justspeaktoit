import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Regional, credential-bound evidence. Pending/deleted clones never become executable presets.
public struct SonioxAccountVoiceInventory: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let maximumVoices = 512 - SonioxTTSCatalog.voices.count
    public static let maximumPageBytes = 524_288
    public let voices: [SonioxTTSAccountVoice]
    public let region: SonioxTTSRegion
    public let context: VoiceAccountCredentialContext
    private let credential: String
    public var description: String { "Soniox \(region.rawValue) inventory (\(voices.count) account voices)" }
    public var debugDescription: String { description }
    public var desktopVoices: [DesktopSpeechVoice] {
        voices.filter { $0.status(for: SonioxTTSCatalog.defaultModel) == .ready }.map {
            .soniox(SonioxTTSCatalog.resolvedVoice(voiceID: $0.providerVoiceID, accountVoices: voices))
        }
    }

    public func matchesCredential(_ value: String) -> Bool {
        credential == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func fetch(
        session: URLSession = .shared, region: SonioxTTSRegion, context: VoiceAccountCredentialContext? = nil,
        credential: @Sendable () async throws -> String
    ) async throws -> Self {
        try Task.checkCancellation()
        let context = context ?? .init(provider: .soniox, sessionID: UUID(), epoch: UUID())
        guard context.provider == .soniox else { throw VoiceAccountDiscoveryError.invalidInventory(.soniox) }
        let key = try VoiceOutputCredentialSlot(provider: .soniox).validatedKey(await credential())
        try Task.checkCancellation()
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        var voices: [SonioxTTSAccountVoice] = [], identifiers = Set<String>(), cursors = Set<String>()
        var cursor: String?
        for _ in 0..<SonioxTTSAPI.maxVoicePages {
            let page = try await receive(session: session, key: key, region: region, cursor: cursor, end: end)
            try Task.checkCancellation()
            guard page.voices.count <= maximumVoices - voices.count else {
                throw VoiceAccountDiscoveryError.oversized(.soniox)
            }
            for voice in page.voices {
                guard valid(voice), identifiers.insert(voice.id.lowercased()).inserted else {
                    throw VoiceAccountDiscoveryError.invalidInventory(.soniox)
                }
                voices.append(voice)
            }
            guard let next = page.nextPageCursor, !next.isEmpty else {
                return Self(voices: voices, region: region, context: context, credential: key)
            }
            guard next.utf8.count <= 4_096,
                  !next.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  cursors.insert(next).inserted else { throw VoiceAccountDiscoveryError.invalidInventory(.soniox) }
            cursor = next
        }
        throw VoiceAccountDiscoveryError.oversized(.soniox)
    }

    private static func receive(
        session: URLSession, key: String, region: SonioxTTSRegion, cursor: String?, end: ContinuousClock.Instant
    ) async throws -> AccountVoicePage {
        do {
            let remaining = ContinuousClock.now.duration(to: end)
            guard remaining > .zero else { throw VoiceAccountDiscoveryError.timedOut(.soniox) }
            let received = try await OpenRouterBoundedResponseTransport.perform(
                SonioxTTSAPI.voiceListRequest(apiKey: key, region: region, cursor: cursor),
                session: session, limit: maximumPageBytes, deadline: remaining
            ) { response in
                guard (200..<300).contains(response.statusCode) else {
                    throw VoiceAccountDiscoveryError.service(.soniox, response.statusCode)
                }
            }
            do { return try JSONDecoder().decode(AccountVoicePage.self, from: received.body) } catch {
                throw VoiceAccountDiscoveryError.invalidInventory(.soniox)
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? VoiceAccountDiscoveryError { throw failure }
            switch error as? OpenRouterBoundedResponseTransport.Failure {
            case .responseTooLarge: throw VoiceAccountDiscoveryError.oversized(.soniox)
            case .timedOut: throw VoiceAccountDiscoveryError.timedOut(.soniox)
            case .invalidResponse: throw VoiceAccountDiscoveryError.invalidInventory(.soniox)
            case nil:
                throw (error as? URLError)?.code == .timedOut
                    ? VoiceAccountDiscoveryError.timedOut(.soniox) : VoiceAccountDiscoveryError.transport(.soniox)
            }
        }
    }

    private static func valid(_ voice: SonioxTTSAccountVoice) -> Bool {
        !voice.id.isEmpty && voice.id.utf8.count <= 256
            && voice.id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
            && SonioxTTSCatalog.voice(forID: voice.id) == nil
            && !voice.name.isEmpty && voice.name.utf8.count <= 256
            && voice.name == voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !voice.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && voice.models.count <= 32
            && Set(voice.models.map(\.model)).count == voice.models.count
    }
}
