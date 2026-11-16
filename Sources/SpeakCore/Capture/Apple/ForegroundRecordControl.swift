import Foundation

/// What the iOS app's primary record control shows.
///
/// The control carries a visible title as well as a symbol, so the action is
/// named on screen at every size class, on iPhone and iPad alike (App Review,
/// Guideline 4, asked for a visible Transcribe control on iPad). The
/// accessibility label keeps the existing state-specific wording, and the
/// visible title is also offered as a Voice Control input label.
public struct ForegroundRecordControl: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording
        case stopping
    }

    public let symbolName: String
    public let title: String
    public let accessibilityLabel: String
    /// Phrases Voice Control accepts, visible title first.
    public let inputLabels: [String]

    public init(phase: Phase, handsFreeArmed: Bool, handsFreeEnabled: Bool) {
        switch phase {
        case .starting:
            self.init(symbolName: "xmark", title: "Cancel", accessibilityLabel: "Cancel starting recording")
        case .stopping:
            self.init(symbolName: "hourglass", title: "Finishing", accessibilityLabel: "Finishing recording")
        case .recording:
            self.init(symbolName: "stop.fill", title: "Stop", accessibilityLabel: "Stop recording")
        case .idle where handsFreeArmed:
            self.init(symbolName: "mic.slash.fill", title: "Disarm", accessibilityLabel: "Disarm hands-free dictation")
        case .idle where handsFreeEnabled:
            self.init(symbolName: "mic.fill", title: "Transcribe", accessibilityLabel: "Arm hands-free dictation")
        case .idle:
            self.init(symbolName: "mic.fill", title: "Transcribe", accessibilityLabel: "Start recording")
        }
    }

    private init(symbolName: String, title: String, accessibilityLabel: String) {
        self.symbolName = symbolName
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.inputLabels = title == accessibilityLabel ? [title] : [title, accessibilityLabel]
    }
}
