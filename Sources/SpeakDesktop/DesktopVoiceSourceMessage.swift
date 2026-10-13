import Foundation
import SpeakCore

/// The narrow native Voice ABI decoded once for both desktop hosts.
public enum DesktopVoiceSourceMessage: Equatable, Sendable {
    case event(DesktopHistoryEvent)
    case preferences(VoiceGenerationOptions)

    public init(action: Int32, source: Int32, text: String, record: String, path: String) throws {
        switch action {
        case 112: self = .event(.stop)
        case 113: self = .event(.voiceImport(path: path, requestID: record))
        case 114: self = .event(.voiceImportCancel(requestID: record))
        case 116: self = .event(.voiceGeneratedPlay(record))
        case 117: self = .event(.voiceGeneratedExport(record, path: path))
        case 118: self = .preferences(try Self.options(source))
        case 110, 111, 115:
            self = .event(try Self.textEvent(action: action, source: source, text: text, record: record, path: path))
        default: throw Failure.invalidAction
        }
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
            guard let flags = Int32(path) else { throw Failure.invalidPreferences }
            return .voiceGenerate(snapshot, options: try options(flags))
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
