import Foundation

/// Source identifiers and wording are shared; membership is not host support.
public enum VoiceOutputSource: Int32, CaseIterable, Sendable {
    case history
    case typedText
    case clipboard
    case externalSelection
    case textFile

    public var displayName: String {
        switch self {
        case .history: "Selected History transcript"
        case .typedText: "Type or paste text"
        case .clipboard: "Clipboard snapshot"
        case .externalSelection: "External selected text (unavailable)"
        case .textFile: "Import text file"
        }
    }
}

/// Captured before asynchronous work. Clipboard text is never a substitute for
/// an external selection, and a History source keeps its original record owner.
public struct VoiceOutputSourceSnapshot: Equatable, Sendable {
    public static let maximumCharacters = 100_000
    public let source: VoiceOutputSource
    public let text: String
    public let recordID: UUID?

    public init(source: VoiceOutputSource, text: String, recordID: UUID? = nil) throws {
        guard source != .externalSelection else { throw Failure.externalSelectionUnavailable }
        guard source != .history || recordID != nil else { throw Failure.missingHistoryRecord }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyText }
        guard text.unicodeScalars.count <= Self.maximumCharacters, !text.utf8.contains(0) else {
            throw Failure.invalidText
        }
        self.source = source
        self.text = text
        self.recordID = source == .history ? recordID : nil
    }

    public enum Failure: LocalizedError {
        case externalSelectionUnavailable, missingHistoryRecord, emptyText, invalidText

        public var errorDescription: String? {
            switch self {
            case .externalSelectionUnavailable:
                "External selected text is unavailable: no external selection target has been captured. "
                    + "Copy explicitly, then choose Clipboard snapshot."
            case .missingHistoryRecord: "Choose a recording in History first."
            case .emptyText: "There is no text to speak or export."
            case .invalidText: "Voice output accepts up to 100,000 characters without embedded nulls."
            }
        }
    }
}
