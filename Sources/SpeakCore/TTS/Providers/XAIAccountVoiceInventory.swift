import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ephemeral account evidence. The credential never enters settings, presentation or usage data.
public struct XAIAccountVoiceInventory: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumResponseBytes = 65_536
    public static let maximumVoices = 512
    public let voices: [XAITTSVoice]
    private let credential: String
    public var description: String { "xAI account inventory (\(voices.count) additional voices)" }
    public var debugDescription: String { description }

    public var desktopVoices: [DesktopSpeechVoice] { voices.map(DesktopSpeechVoice.xai) }

    public func matchesCredential(_ value: String) -> Bool {
        credential == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func contains(_ voice: DesktopSpeechVoice) -> Bool { desktopVoices.contains(voice) }

    public func voice(forID identifier: String) -> XAITTSVoice? {
        voices.first { $0.providerVoiceID == identifier }
    }

    public static func fetch(
        session: URLSession = .shared, credential: @Sendable () async throws -> String
    ) async throws -> Self {
        try Task.checkCancellation()
        let key = try await credential().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !key.isEmpty else { throw DesktopXAISpeechError.missingCredential }
        let builtIn = try await receive(XAITTSAPI.voiceListRequest(apiKey: key), session: session) ?? Data()
        var listed = try listing { try XAITTSAPI.decodedVoices(from: builtIn) }
        var token: String?
        for page in 0..<XAITTSAPI.maximumCustomVoicePages {
            try Task.checkCancellation()
            // Custom voices are region- and plan-gated: no library means none. A
            // refusal after the first page is a failure, never a partial list.
            guard let body = try await receive(
                XAITTSAPI.customVoiceListRequest(apiKey: key, paginationToken: token), session: session,
                absentStatuses: page == 0 ? XAITTSAPI.customVoicesUnavailableStatuses : []
            ) else { break }
            let custom = try listing { try XAITTSAPI.decodedCustomVoicePage(from: body) }
            listed += custom.voices
            guard listed.count <= maximumVoices else { throw XAIAccountVoiceDiscoveryError.oversized }
            guard let next = custom.nextToken else { break }
            guard page + 1 < XAITTSAPI.maximumCustomVoicePages else { throw XAIAccountVoiceDiscoveryError.oversized }
            token = next
        }
        try Task.checkCancellation()
        return try inventory(listed, key: key)
    }

    private static func listing<Value>(_ decode: () throws -> Value) throws -> Value {
        do { return try decode() } catch { throw XAIAccountVoiceDiscoveryError.invalidInventory }
    }

    private struct AbsentListing: Error {}

    /// The body of a successful response, or nil for a status in `absentStatuses`.
    private static func receive(
        _ request: URLRequest, session: URLSession, absentStatuses: Set<Int> = []
    ) async throws -> Data? {
        do {
            let body = try await OpenRouterBoundedResponseTransport.perform(
                request, session: session, limit: maximumResponseBytes, deadline: .seconds(20)
            ) { value in
                if absentStatuses.contains(value.statusCode) { throw AbsentListing() }
                guard (200..<300).contains(value.statusCode) else {
                    throw XAIAccountVoiceDiscoveryError.service(value.statusCode)
                }
            }.body
            return body
        } catch is AbsentListing {
            return nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? XAIAccountVoiceDiscoveryError { throw failure }
            switch error as? OpenRouterBoundedResponseTransport.Failure {
            case .responseTooLarge: throw XAIAccountVoiceDiscoveryError.oversized
            case .timedOut: throw XAIAccountVoiceDiscoveryError.timedOut
            case .invalidResponse: throw XAIAccountVoiceDiscoveryError.invalidInventory
            case nil: throw XAIAccountVoiceDiscoveryError.transport
            }
        }
    }

    private static func inventory(_ listed: [XAITTSVoice], key: String) throws -> Self {
        guard listed.count <= maximumVoices else { throw XAIAccountVoiceDiscoveryError.oversized }
        var identifiers = Set<String>()
        var additional: [XAITTSVoice] = []
        for voice in listed {
            guard valid(voice.id), valid(voice.name),
                  !voice.id.lowercased().hasPrefix(XAITTSCatalog.voiceIDPrefix),
                  identifiers.insert(voice.id).inserted else {
                throw XAIAccountVoiceDiscoveryError.invalidInventory
            }
            if XAITTSCatalog.voice(forID: voice.id) == nil { additional.append(voice) }
        }
        return Self(voices: additional, credential: key)
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public enum XAIAccountVoiceDiscoveryError: LocalizedError, Equatable {
    case service(Int), invalidInventory, oversized, timedOut, transport, credentialChanged

    public var errorDescription: String? {
        switch self {
        case .service(let status): "xAI account voice listing failed (HTTP \(status)). No new listing was accepted."
        case .invalidInventory: "xAI returned an invalid voice listing. No new listing was accepted."
        case .oversized: "The xAI voice listing exceeds this host's bounded inventory limit."
        case .timedOut: "The xAI voice listing did not finish within the discovery budget."
        case .transport: "The xAI voice listing could not be received. Try Refresh again."
        case .credentialChanged:
            "The xAI key changed. Refresh account voices for the current key before using this voice."
        }
    }
}
