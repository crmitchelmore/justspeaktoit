import Foundation

/// Command preferences captured with an utterance, never its clipboard content.
public struct ClipboardVoiceCommandPolicy: Equatable, Sendable {
    public let isEnabled: Bool
    public let customTriggers: String

    public init(isEnabled: Bool, customTriggers: String) {
        self.isEnabled = isEnabled
        self.customTriggers = customTriggers
    }
}
