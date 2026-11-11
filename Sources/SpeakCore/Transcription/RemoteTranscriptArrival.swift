import Foundation

/// What the Mac should do when a transcript captured on the phone or watch
/// arrives through CloudKit history sync (issue #1007).
///
/// The Mac lane is the history push, not a bespoke transport: iOS already
/// uploads every transcript to the shared zone within seconds, and this decides
/// whether the arrival is worth interrupting the user for. Every rule here
/// exists to stop a routine sync from spraying notifications:
///
/// - only captures from a phone or a watch (a Mac's own entries come back to it
///   on every sync);
/// - only entries this Mac has not already seen, so a full re-reconciliation or
///   a change-token reset is silent;
/// - only entries younger than `freshnessWindow`, so a first launch that
///   downloads a year of history notifies about none of it.
///
/// Auto-paste is off unless the user turned it on. Text that appears at the
/// cursor without being asked for is a data-integrity hazard, so the default is
/// a notification with a Paste action the user chooses to press.
public enum RemoteTranscriptArrival {
    /// How new an arriving capture has to be to be worth a notification.
    public static let freshnessWindow: TimeInterval = 60

    /// How far ahead of this Mac's clock an entry may be dated and still be
    /// treated as a live arrival.
    ///
    /// The age check alone accepted *every* negative age, so an entry dated
    /// arbitrarily far in the future passed the backlog guard permanently.
    /// Anything with write access to the account's private history zone could
    /// label such an entry `ios` and have it notify — or, with auto-paste
    /// enabled, paste into whatever the user has focused — on this and every
    /// later sync. Real devices disagree by seconds, so a bound of one
    /// freshness window covers honest clock skew and nothing else.
    public static let futureSkewAllowance: TimeInterval = freshnessWindow

    public struct Input: Equatable, Sendable {
        public let originPlatform: String
        public let createdAt: Date
        public let text: String
        /// False when this Mac already had the entry, so a re-sync is silent.
        public let isNewToThisMac: Bool
        /// The user's explicit opt-in to pasting at the cursor.
        public let autoPasteEnabled: Bool

        public init(
            originPlatform: String,
            createdAt: Date,
            text: String,
            isNewToThisMac: Bool,
            autoPasteEnabled: Bool
        ) {
            self.originPlatform = originPlatform
            self.createdAt = createdAt
            self.text = text
            self.isNewToThisMac = isNewToThisMac
            self.autoPasteEnabled = autoPasteEnabled
        }
    }

    public enum IgnoreReason: String, Equatable, Sendable {
        case noText
        case notAPhoneOrWatchCapture
        case alreadyKnown
        case tooOld
        /// Dated further into the future than clock skew can explain.
        case datedInTheFuture
    }

    public struct Alert: Equatable, Sendable {
        public let title: String
        public let body: String
        public let transcript: String

        public init(title: String, body: String, transcript: String) {
            self.title = title
            self.body = body
            self.transcript = transcript
        }
    }

    public enum Decision: Equatable, Sendable {
        case ignore(IgnoreReason)
        /// Post a notification carrying Paste and Copy actions. The safe
        /// default: nothing is inserted until the user asks.
        case notify(Alert)
        /// The user opted in to auto-paste. Paste first, then report what
        /// actually happened via `outcomeAlert`.
        case pasteAtCursor(Alert)
    }

    public static func decide(_ input: Input, now: Date = Date()) -> Decision {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignore(.noText) }
        guard ["ios", "watchos"].contains(input.originPlatform) else {
            return .ignore(.notAPhoneOrWatchCapture)
        }
        guard input.isNewToThisMac else { return .ignore(.alreadyKnown) }
        let age = now.timeIntervalSince(input.createdAt)
        guard age <= freshnessWindow else { return .ignore(.tooOld) }
        guard age >= -futureSkewAllowance else { return .ignore(.datedInTheFuture) }

        let alert = Alert(
            title: "New from \(deviceName(for: input.originPlatform))",
            body: TranscriptPreview.short(text),
            transcript: text
        )
        return input.autoPasteEnabled ? .pasteAtCursor(alert) : .notify(alert)
    }

    /// The notification an auto-paste attempt leaves behind. The body reports
    /// the *result* of the paste, so a failed insertion never reads as a
    /// successful one (issues #945, #952).
    public static func outcomeAlert(
        for alert: Alert,
        pasted: Bool,
        failureReason: String?
    ) -> Alert {
        guard pasted else {
            let reason = failureReason.map { " \($0)" } ?? ""
            return Alert(
                title: alert.title,
                body: "Could not paste it at the cursor.\(reason) Use Paste or Copy here instead.",
                transcript: alert.transcript
            )
        }
        return Alert(
            title: alert.title,
            body: "Pasted at your cursor: \(alert.body)",
            transcript: alert.transcript
        )
    }

    public static func deviceName(for originPlatform: String) -> String {
        switch originPlatform {
        case "ios": return "iPhone"
        case "watchos": return "Apple Watch"
        case "macos": return "Mac"
        default: return "another device"
        }
    }
}
