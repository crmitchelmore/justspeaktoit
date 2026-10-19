import Foundation
import SpeakCore

/// The narrow native Voice ABI decoded once for both desktop hosts.
public enum DesktopVoiceSourceMessage: Equatable, Sendable {
    case event(DesktopHistoryEvent)
    case preferences(VoiceGenerationOptions)
    case synthesisPreferences(VoiceSynthesisOptions, requestID: String)
    case audioFormat(String)
    case usageReport(text: String, requestID: String)
    case usageTracking(Bool, requestID: String)
    case discoveryOpen(String), discoveryRefresh(String), discoveryClose(String)
    case discoveryOpenModern(UUID)
    case discoveryChoose(voiceID: String, requestID: String)
    case discoveryProvider(VoiceAccountCredentialContext)

    public init(action: Int32, source: Int32, text: String, record: String, path: String) throws {
        switch action {
        case 112: self = .event(.stop)
        case 113: self = .event(.voiceImport(path: path, requestID: record))
        case 114: self = .event(.voiceImportCancel(requestID: record))
        case 116: self = .event(.voiceGeneratedPlay(record))
        case 117: self = .event(.voiceGeneratedExport(record, path: path))
        case 118:
            self = try Self.preferenceMessage(source: source, text: text, record: record, path: path)
        case 119:
            guard text.utf8.count <= 1_024, !record.isEmpty, record.utf8.count <= 64,
                  record.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { throw Failure.invalidPreferences }
            self = .synthesisPreferences(
                try JSONDecoder().decode(VoiceSynthesisOptions.self, from: Data(text.utf8)), requestID: record
            )
        case 110, 111, 115:
            self = .event(try Self.textEvent(action: action, source: source, text: text, record: record, path: path))
        default: throw Failure.invalidAction
        }
    }

    private static func preferenceMessage(
        source: Int32, text: String, record: String, path: String
    ) throws -> Self {
        if path.isEmpty {
            guard text.isEmpty, record.isEmpty else { throw Failure.invalidPreferences }
            return .preferences(try options(source))
        }
        guard !record.isEmpty, record.utf8.count <= 64,
              record.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { throw Failure.invalidPreferences }
        if path.hasPrefix("account-") {
            return try discoveryMessage(source: source, text: text, record: record, path: path)
        }
        switch path {
        case "audio-format":
            guard source == -1, VoiceAudioFormat(rawValue: text) != nil else { throw Failure.invalidPreferences }
            return .audioFormat(text)
        case "usage-report":
            guard source == -1, text.unicodeScalars.count <= VoiceOutputSourceSnapshot.maximumCharacters else {
                throw Failure.invalidPreferences
            }
            return .usageReport(text: text, requestID: record)
        case "usage-tracking":
            guard source == 0 || source == 1, text.isEmpty else { throw Failure.invalidPreferences }
            return .usageTracking(source == 1, requestID: record)
        default: throw Failure.invalidPreferences
        }
    }

    private static func discoveryMessage(
        source: Int32, text: String, record: String, path: String
    ) throws -> Self {
        guard source == -1 else { throw Failure.invalidPreferences }
        if let message = try contextualDiscoveryMessage(text: text, record: record, path: path) { return message }
        switch path {
        case "account-open", "account-refresh", "account-close":
            guard text.isEmpty else { throw Failure.invalidPreferences }
            switch path {
            case "account-open": return .discoveryOpen(record)
            case "account-refresh": return .discoveryRefresh(record)
            default: return .discoveryClose(record)
            }
        case "account-choose":
            guard VoiceAccountProvider.all.contains(where: {
                text.hasPrefix($0.id + "/") && text.utf8.count > $0.id.utf8.count + 1
            }), text.utf8.count <= 260,
                  text == text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { throw Failure.invalidPreferences }
            return .discoveryChoose(voiceID: text, requestID: record)
        default: throw Failure.invalidPreferences
        }
    }

    private static func contextualDiscoveryMessage(text: String, record: String, path: String) throws -> Self? {
        switch path {
        case "account-provider": return try providerMessage(text: text, record: record)
        case "account-open-modern":
            guard text.isEmpty, record.utf8.count == 36, let session = UUID(uuidString: record) else {
                throw Failure.invalidPreferences
            }
            return .discoveryOpenModern(session)
        default: return nil
        }
    }

    private static func providerMessage(text: String, record: String) throws -> Self {
        let fields = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard record.utf8.count == 36, let session = UUID(uuidString: record),
              fields.count == 2, fields[1].utf8.count == 36,
              let epoch = UUID(uuidString: String(fields[1])) else { throw Failure.invalidPreferences }
        return .discoveryProvider(try .init(
            provider: VoiceAccountProvider(id: String(fields[0])), sessionID: session, epoch: epoch))
    }

    private static func textEvent(
        action: Int32, source: Int32, text: String, record: String, path: String
    ) throws -> DesktopHistoryEvent {
        guard let kind = VoiceOutputSource(rawValue: source) else {
            throw VoiceOutputSourceSnapshot.Failure.invalidText
        }
        let snapshot = try VoiceOutputSourceSnapshot(source: kind, text: text, recordID: UUID(uuidString: record))
        switch action {
        case 110: return .voiceRead(snapshot)
        case 111: return .voiceExport(snapshot, path: path)
        case 115:
            let fields = path.split(separator: "|", omittingEmptySubsequences: false)
            guard (1...2).contains(fields.count), let flags = Int32(fields[0]) else {
                throw Failure.invalidPreferences
            }
            let legacy = try options(flags)
            if fields.count == 1 { return .voiceGenerate(snapshot, options: legacy) }
            guard let format = VoiceAudioFormat(rawValue: String(fields[1])) else { throw Failure.invalidPreferences }
            return .voiceGenerate(snapshot, options: .init(
                autoPlay: legacy.autoPlay, saveToRecordings: legacy.saveToRecordings, format: format))
        default: throw Failure.invalidAction
        }
    }

    private static func options(_ flags: Int32) throws -> VoiceGenerationOptions {
        guard let options = VoiceGenerationOptions(nativeFlags: flags) else { throw Failure.invalidPreferences }
        return options
    }

    private enum Failure: LocalizedError {
        case invalidAction, invalidPreferences
        var errorDescription: String? {
            switch self {
            case .invalidAction: "The native Voice Output action is not supported."
            case .invalidPreferences: "The generated voice preferences are invalid."
            }
        }
    }
}
