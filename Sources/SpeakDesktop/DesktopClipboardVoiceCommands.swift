import Foundation
import SpeakCore

public enum DesktopClipboardReadError: LocalizedError, Equatable, Sendable {
    case unsupported(String)
    case tooLarge
    case invalidText
    case timedOut
    case busy
    case nativeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .tooLarge: return "The clipboard text exceeds the supported read limit."
        case .invalidText: return "The clipboard does not contain valid text."
        case .timedOut: return "The clipboard did not respond before the read deadline."
        case .busy: return "A previous clipboard read is still cleaning up."
        case .nativeFailure(let reason): return reason
        }
    }
}

/// Final-only command expansion. Native readers must bound and cancel their
/// operation; no capture callback, output job or clipboard write is involved.
public enum DesktopClipboardVoiceCommands {
    public static let maximumClipboardUTF8Bytes = 1_048_576

    public static func process(
        _ text: String,
        policy: ClipboardVoiceCommandPolicy,
        readClipboard: @Sendable () async throws -> String?
    ) async throws -> String {
        try Task.checkCancellation()
        guard policy.isEnabled else { return text }
        let recognized = await MainActor.run {
            VoiceCommandProcessor(configuration: .init(policy: policy, clipboardText: { nil }))
                .recognizesClipboardCommand(in: text)
        }
        try Task.checkCancellation()
        guard recognized else { return text }
        let clipboard = try await readClipboard()
        try Task.checkCancellation()
        if let clipboard, clipboard.utf8.count > maximumClipboardUTF8Bytes {
            throw DesktopClipboardReadError.tooLarge
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            return VoiceCommandProcessor(configuration: .init(policy: policy, clipboardText: { clipboard }))
                .process(text)
        }
    }
}
