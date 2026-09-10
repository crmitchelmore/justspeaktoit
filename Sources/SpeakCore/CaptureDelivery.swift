import Foundation

// MARK: - Preview

/// A short, single-line rendering of a transcript for a notification, a chip
/// or a Live Activity row. The full text is never put on a surface that sits
/// over whatever the user is doing.
public enum TranscriptPreview {
    public static let defaultLimit = 42

    public static func short(_ text: String, limit: Int = defaultLimit) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        let clipped = String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return clipped + "\u{2026}"
    }
}

// MARK: - Lanes

/// Where a completed transcript actually ended up.
///
/// These are *outcomes*, not intentions: a lane is only reported once the work
/// that defines it has been done and its result observed.
public enum CaptureDeliveryLane: String, Codable, Equatable, Sendable, CaseIterable {
    /// The Just Speak keyboard inserted the transcript into the document it
    /// was open in, and said so by claiming the offer (issue #1002). Writing
    /// the offer is not this lane: an offer is an intention, and an intention
    /// the keyboard never acts on is not a delivery.
    case keyboardField
    /// The transcript was written to the pasteboard and the write verified.
    case clipboard
    /// The History entry is the only landing place — either because the user
    /// asked for that, or because every other lane failed.
    case history
    /// Nothing was delivered anywhere.
    case none
}

// MARK: - The Auto destination policy (#1008)

/// Chooses a lane for the `Auto` destination at stop time.
///
/// ## Why there is no "Mac" lane here
///
/// The original idea was "field if the keyboard is open, **Mac if reachable**,
/// else clipboard". Nothing available to the phone establishes that a Mac is
/// *reachable*. A saved pairing, an enabled setting, or an iCloud account being
/// signed in are all statements about configuration, and treating any of them
/// as reachability is exactly the failure of issue #952 — a UI that claimed to
/// send while no transcript ever arrived. The local transport that could have
/// answered the question was deliberately removed with that issue.
///
/// So Auto never gambles on a Mac. The Mac lane runs in parallel for *every*
/// capture instead — the transcript is uploaded to the shared CloudKit history
/// zone and a Handoff pointer is published (issues #1006, #1007) — and the
/// receipt reports only what the phone can observe: that the entry was queued
/// for iCloud. It never claims a Mac received anything, because it cannot know.
public enum AutoDestinationPolicy {
    public struct Inputs: Equatable, Sendable {
        /// The final transcript is empty or whitespace only.
        public let transcriptIsEmpty: Bool
        /// The Just Speak keyboard *inserted* the transcript into the document
        /// it was open in, evidenced by its claim on the offer. Not "a target
        /// was advertised" and not "an offer was published": Auto skips the
        /// clipboard on the strength of this, so anything short of an observed
        /// insertion has to keep the clipboard.
        public let keyboardInsertedIntoField: Bool
        /// The shared App Group is writable, i.e. the keyboard has Full
        /// Access. Without it no offer can be published at all.
        public let keyboardOfferAvailable: Bool

        public init(
            transcriptIsEmpty: Bool,
            keyboardInsertedIntoField: Bool,
            keyboardOfferAvailable: Bool
        ) {
            self.transcriptIsEmpty = transcriptIsEmpty
            self.keyboardInsertedIntoField = keyboardInsertedIntoField
            self.keyboardOfferAvailable = keyboardOfferAvailable
        }
    }

    public struct Plan: Equatable, Sendable {
        /// The lane Auto is aiming at. The receipt reports what happened, which
        /// may be a different lane when this one fails.
        public let preferredLane: CaptureDeliveryLane
        /// Whether the pasteboard should be written at stop.
        public let writesClipboard: Bool
        /// One sentence of why, for the log and for the settings copy.
        public let explanation: String

        public init(preferredLane: CaptureDeliveryLane, writesClipboard: Bool, explanation: String) {
            self.preferredLane = preferredLane
            self.writesClipboard = writesClipboard
            self.explanation = explanation
        }
    }

    public static func plan(_ inputs: Inputs) -> Plan {
        guard !inputs.transcriptIsEmpty else {
            return Plan(
                preferredLane: .none,
                writesClipboard: false,
                explanation: "No words were transcribed, so there is nothing to deliver."
            )
        }
        guard inputs.keyboardOfferAvailable else {
            return Plan(
                preferredLane: .clipboard,
                writesClipboard: true,
                explanation: "Keyboard delivery is unavailable, so the transcript is copied to the clipboard."
            )
        }
        guard inputs.keyboardInsertedIntoField else {
            return Plan(
                preferredLane: .clipboard,
                writesClipboard: true,
                explanation: "The keyboard did not take the transcript, so it is copied to the clipboard "
                    + "and offered to the keyboard for later."
            )
        }
        return Plan(
            preferredLane: .keyboardField,
            writesClipboard: false,
            explanation: "The Just Speak keyboard put the transcript in the text field you were typing "
                + "in, so the clipboard is left alone."
        )
    }
}

// MARK: - The Mac lane's outcome

/// What the phone can honestly say about the CloudKit history lane (#1007).
///
/// Every case is a fact about *this device's* upload. None of them is a claim
/// that a Mac received, showed, or pasted anything: the phone has no evidence
/// of that, and inventing it is the #952 bug.
public enum MacLaneOutcome: Equatable, Sendable {
    /// The lane was not run for this capture — history sync is off, or there
    /// was no entry to upload.
    case notAttempted
    /// The entry was handed to the history sync engine, which uploads it and
    /// retries on failure. A fact about this phone's queue, and nothing more:
    /// the receipt is written before any round trip completes, and the phone
    /// never learns whether a Mac read it.
    case queuedForICloud
    /// iCloud is not available on this device, so nothing was queued.
    case iCloudUnavailable
    /// The upload was attempted and rejected; the entry stays pending.
    case uploadFailed

    /// The clause the receipt appends. `nil` adds nothing.
    public var receiptClause: String? {
        switch self {
        case .notAttempted:
            return nil
        case .queuedForICloud:
            return "Queued for iCloud History, where a Mac signed in to the same account can pick it up."
        case .iCloudUnavailable:
            return "Not sent to iCloud \u{2014} iCloud is unavailable on this iPhone."
        case .uploadFailed:
            return "The iCloud upload did not go through; it will be retried."
        }
    }
}

// MARK: - The receipt (#1008, and the honesty rule from #945 / #952)

/// What the user is told happened. Built *after* every side effect has run and
/// reported its own result, so it can only describe work that completed.
public struct CaptureReceipt: Equatable, Sendable {
    public let lane: CaptureDeliveryLane
    public let headline: String
    public let detail: String?

    public init(lane: CaptureDeliveryLane, headline: String, detail: String?) {
        self.lane = lane
        self.headline = headline
        self.detail = detail
    }

    /// One line for a Live Activity row or a log.
    public var summary: String {
        guard let detail else { return headline }
        return "\(headline) \u{2014} \(detail)"
    }
}

public enum CaptureReceiptBuilder {
    /// What became of the keyboard offer by the time the receipt was written.
    ///
    /// The distinction that matters is between *publishing an offer* and
    /// *observing an insertion*. An offer bound to the open document is only a
    /// message left in the App Group; the keyboard inserts it when it next
    /// polls and finds the same document still focused. Close the keyboard,
    /// move field, or let the extension be suspended in between and that never
    /// happens — so only `.insertedInField`, which is backed by the
    /// extension's own claim, may be reported as delivery to a field.
    public enum KeyboardOfferOutcome: Equatable, Sendable, CaseIterable {
        /// No offer was written for this capture.
        case notOffered
        /// An unbound, late-pickup offer is waiting in the keyboard strip.
        case latePickupWaiting
        /// An offer bound to the open document was written and the keyboard
        /// claimed it, which it does only after the proxy accepted the text.
        case insertedInField
        /// An offer bound to the open document was written, but no insertion
        /// was observed before the deadline. The words are not in the field.
        case targetedButNotInserted
    }

    /// The observed result of every side effect a stop performed.
    public struct Outcome: Equatable, Sendable {
        public let transcriptIsEmpty: Bool
        /// The lane the policy (or the user's fixed destination) aimed at.
        public let preferredLane: CaptureDeliveryLane
        /// What the keyboard offer, if any, actually came to.
        public let keyboard: KeyboardOfferOutcome
        /// `nil` when the pasteboard was deliberately not written.
        public let clipboardWriteSucceeded: Bool?
        /// A History entry exists for this capture *and its write reached
        /// disk*. An entry that only exists in memory is not saved.
        public let savedToHistory: Bool
        public let mac: MacLaneOutcome

        public init(
            transcriptIsEmpty: Bool,
            preferredLane: CaptureDeliveryLane,
            keyboard: KeyboardOfferOutcome,
            clipboardWriteSucceeded: Bool?,
            savedToHistory: Bool,
            mac: MacLaneOutcome
        ) {
            self.transcriptIsEmpty = transcriptIsEmpty
            self.preferredLane = preferredLane
            self.keyboard = keyboard
            self.clipboardWriteSucceeded = clipboardWriteSucceeded
            self.savedToHistory = savedToHistory
            self.mac = mac
        }
    }

    public static func receipt(for outcome: Outcome) -> CaptureReceipt {
        guard !outcome.transcriptIsEmpty else {
            return CaptureReceipt(
                lane: .none,
                headline: "Nothing to deliver",
                detail: "No words were transcribed, so nothing was copied or inserted."
            )
        }

        var clauses: [String] = []

        // 1. The field. Reported only when the keyboard extension claimed the
        //    offer, which it does after the text document proxy accepted the
        //    text — never for an offer that was merely published.
        if outcome.keyboard == .insertedInField {
            clauses.append("The Just Speak keyboard put it there.")
            if outcome.clipboardWriteSucceeded == false {
                clauses.append("The clipboard write did not go through.")
            }
            appendFallbacks(&clauses, outcome: outcome, mentionHistory: true)
            return CaptureReceipt(
                lane: .keyboardField,
                headline: "Put into the field you were typing in",
                detail: joined(clauses)
            )
        }

        // 2. The clipboard, when the write was verified.
        if outcome.clipboardWriteSucceeded == true {
            appendKeyboardShortfall(&clauses, outcome: outcome, wentToClipboard: true)
            appendFallbacks(&clauses, outcome: outcome, mentionHistory: true)
            return CaptureReceipt(lane: .clipboard, headline: "Copied", detail: joined(clauses))
        }

        // 3. Every clipboard failure lands here, and says so rather than
        //    claiming a copy that did not happen (issue #945).
        if outcome.clipboardWriteSucceeded == false {
            clauses.append("The clipboard write did not go through, so nothing was copied.")
        }
        appendKeyboardShortfall(&clauses, outcome: outcome, wentToClipboard: false)
        appendFallbacks(&clauses, outcome: outcome, mentionHistory: false)

        guard outcome.savedToHistory else {
            return CaptureReceipt(
                lane: .none,
                headline: "Not delivered",
                detail: joined(clauses) ?? "The transcript could not be saved anywhere."
            )
        }
        return CaptureReceipt(lane: .history, headline: "Saved to History", detail: joined(clauses))
    }

    /// Says what the keyboard lane did *not* do, whenever Auto aimed at it and
    /// the words ended up somewhere else. Silence here is what let a capture
    /// read as field delivery while the transcript sat in History.
    private static func appendKeyboardShortfall(
        _ clauses: inout [String],
        outcome: Outcome,
        wentToClipboard: Bool
    ) {
        switch outcome.keyboard {
        case .insertedInField, .notOffered:
            if outcome.preferredLane == .keyboardField, wentToClipboard {
                clauses.append("The keyboard was no longer open, so the transcript went to the clipboard.")
            }
        case .targetedButNotInserted:
            clauses.append(
                "The Just Speak keyboard did not put it in that field \u{2014} it was no longer open there."
            )
        case .latePickupWaiting:
            clauses.append(
                wentToClipboard
                    ? "The Just Speak keyboard can also insert it for the next 10 minutes."
                    : "The Just Speak keyboard can insert it for the next 10 minutes."
            )
        }
    }

    /// `mentionHistory` is false when History is already the headline, so the
    /// receipt never says the same thing twice.
    private static func appendFallbacks(
        _ clauses: inout [String],
        outcome: Outcome,
        mentionHistory: Bool
    ) {
        if mentionHistory, outcome.savedToHistory {
            clauses.append("Also in History on this iPhone.")
        }
        if let macClause = outcome.mac.receiptClause {
            clauses.append(macClause)
        }
    }

    private static func joined(_ clauses: [String]) -> String? {
        clauses.isEmpty ? nil : clauses.joined(separator: " ")
    }
}
