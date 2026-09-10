import Foundation

// MARK: - Hardware trigger routing (#1002)

/// Decides what a hardware trigger (Action Button, Siri, Shortcuts, Control
/// Centre) should do when a keyboard-owned dictation is already in flight.
///
/// Today those entry points see `SharedTranscriptionState.isRecording` or a
/// busy service and either refuse outright or stop with the *hardware*
/// destination, discarding the field the keyboard was aiming at. Sharing one
/// session means a physical press finishes the keyboard's dictation into its
/// own field instead.
public enum KeyboardSessionRouting {
    public enum Decision: Equatable, Sendable {
        /// A keyboard-owned dictation is live. Finish it, so the transcript
        /// lands in the field the keyboard opened it for.
        case finishKeyboardSession(UUID)
        /// A keyboard request exists but recording has not begun. A hardware
        /// press must not collide with the start-up it would race.
        case keyboardSessionStarting
        /// No keyboard session owns the microphone; the caller's own start or
        /// stop logic applies unchanged.
        case proceed
    }

    public static func decision(
        handoff: KeyboardHandoffRecord?,
        now: Date = Date()
    ) -> Decision {
        guard let handoff, handoff.expiresAt > now else { return .proceed }
        switch handoff.phase {
        case .requested:
            return .keyboardSessionStarting
        case .recording, .finishRequested, .transcribing:
            // `requestFinish` is idempotent, so repeating it while the app is
            // already finalising is a safe no-op rather than a second stop.
            return .finishKeyboardSession(handoff.requestID)
        case .completed, .cancelled, .failed:
            return .proceed
        }
    }
}

// MARK: - Publishing an offer (#1002, #1003)

/// Builds the offer a completed capture should publish, if any.
public enum KeyboardDeliveryPlanner {
    /// - Parameters:
    ///   - transcript: the final text; an empty or whitespace-only transcript
    ///     is never offered.
    ///   - target: the keyboard's open-target advertisement, if it has one.
    ///     A fresh target promotes the offer to `.targetedInsert`.
    public static func plan(
        transcript: String,
        source: KeyboardPickupOffer.Source,
        target: KeyboardTargetRecord?,
        offerID: UUID = UUID(),
        now: Date = Date()
    ) -> KeyboardPickupOffer? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let target, target.isOpen(now: now) {
            return KeyboardPickupOffer(
                offerID: offerID,
                text: text,
                source: source,
                mode: .targetedInsert,
                createdAt: now,
                expiresAt: now.addingTimeInterval(KeyboardPickupOffer.targetedInsertLifetime),
                originDocumentIdentifier: target.documentIdentifier
            )
        }
        return KeyboardPickupOffer(
            offerID: offerID,
            text: text,
            source: source,
            mode: .latePickup,
            createdAt: now,
            expiresAt: now.addingTimeInterval(KeyboardPickupOffer.latePickupLifetime),
            originDocumentIdentifier: nil
        )
    }
}

// MARK: - Consuming an offer (#1002, #1003)

/// Decides what, if anything, the keyboard may do with a pending offer.
///
/// The governing rule is that an offer never inserts itself into a field the
/// user did not aim it at: auto-insertion requires an exact
/// `documentIdentifier` match against the document the capture belonged to,
/// and everything else is one explicit tap on a chip the user can dismiss.
public enum KeyboardPickupPolicy {
    public enum Offering: Equatable, Sendable {
        case none
        case chip(Chip)
        case autoInsert(text: String)
    }

    public struct Chip: Equatable, Sendable {
        public let offerID: UUID
        public let text: String
        public let preview: String
        public let sourceName: String
        public let ageDescription: String

        public init(
            offerID: UUID,
            text: String,
            preview: String,
            sourceName: String,
            ageDescription: String
        ) {
            self.offerID = offerID
            self.text = text
            self.preview = preview
            self.sourceName = sourceName
            self.ageDescription = ageDescription
        }

        /// The single line the keyboard strip shows, e.g.
        /// `Insert "Remind Sam about…" · Watch · 40 s ago`.
        public var label: String {
            "Insert \u{201C}\(preview)\u{201D} · \(sourceName) · \(ageDescription)"
        }
    }

    public static let previewLimit = 42

    // swiftlint:disable:next function_parameter_count
    public static func offering(
        offer: KeyboardPickupOffer?,
        claim: KeyboardPickupClaim?,
        currentDocumentIdentifier: UUID?,
        isSecureField: Bool,
        handoffInFlight: Bool,
        preferences: KeyboardDeliveryPreferences,
        now: Date = Date()
    ) -> Offering {
        guard let offer, offer.expiresAt > now else { return .none }
        // Already taken or dismissed in this keyboard.
        guard claim?.offerID != offer.offerID else { return .none }
        // Never show a transcript preview over a password field, and never
        // insert into one.
        guard !isSecureField else { return .none }
        // A live dictation owns the strip and the caret; a stale offer must not
        // compete with the words the user is saying right now.
        guard !handoffInFlight else { return .none }

        let matchesOrigin = offer.originDocumentIdentifier != nil
            && offer.originDocumentIdentifier == currentDocumentIdentifier
        switch offer.mode {
        case .targetedInsert:
            // The physical press while this very field was open is the
            // instruction. A different field gets nothing at all — not even a
            // chip — because the user aimed those words somewhere specific.
            return matchesOrigin ? .autoInsert(text: offer.text) : .none
        case .latePickup:
            if matchesOrigin, preferences.autoInsertsMatchingPickup {
                return .autoInsert(text: offer.text)
            }
            return .chip(
                Chip(
                    offerID: offer.offerID,
                    text: offer.text,
                    preview: preview(offer.text),
                    sourceName: offer.source.displayName,
                    ageDescription: ageDescription(since: offer.createdAt, now: now)
                )
            )
        }
    }

    /// A short, single-line preview. The full transcript is never rendered in
    /// the strip: it sits above whatever app the user is in.
    public static func preview(_ text: String, limit: Int = previewLimit) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        let clipped = String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return clipped + "\u{2026}"
    }

    public static func ageDescription(since createdAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(createdAt).rounded()))
        if seconds < 60 { return "\(seconds) s ago" }
        return "\(seconds / 60) min ago"
    }
}

// MARK: - Handing the keyboard back (#1005)

/// Decides whether to call `advanceToNextInputMode()` after an insertion.
///
/// `advanceToNextInputMode()` moves to the *next* enabled keyboard. There is no
/// API to name a keyboard or to go back to the previous one, so "next" only
/// equals "the one the user was typing on" when exactly two keyboards are
/// enabled. With three or more it would land the user somewhere arbitrary, so
/// the hand-back stays off and the setup screen explains why rather than
/// silently doing the wrong thing.
public enum KeyboardHandBackPolicy {
    /// The only enabled-keyboard count for which "next" is provably "back".
    public static let requiredInputModeCount = 2

    public static func shouldAdvanceToNextInputMode(
        preferences: KeyboardDeliveryPreferences,
        activeInputModeCount: Int
    ) -> Bool {
        preferences.handsBackAfterInsert && activeInputModeCount == requiredInputModeCount
    }

    /// What the setup screen should tell the user about their current setup.
    /// `nil` when hand-back is switched off and there is nothing to explain.
    public static func coaching(
        preferences: KeyboardDeliveryPreferences,
        activeInputModeCount: Int
    ) -> String? {
        guard preferences.handsBackAfterInsert else {
            return "Hand back is off. After inserting, tap the globe key yourself to return to typing."
        }
        if activeInputModeCount < requiredInputModeCount {
            return "Add one typing keyboard alongside Just Speak so there is somewhere to hand back to."
        }
        if activeInputModeCount == requiredInputModeCount {
            return "Two keyboards are enabled, so the globe key is one predictable tap each way. "
                + "Just Speak hands the keyboard back automatically after it inserts."
        }
        return "\(activeInputModeCount) keyboards are enabled. iOS only offers \u{201C}next keyboard\u{201D}, "
            + "never \u{201C}previous\u{201D}, so Just Speak will not hand the keyboard back — "
            + "it would land somewhere you did not choose. Keep it to two keyboards to turn this on."
    }
}
