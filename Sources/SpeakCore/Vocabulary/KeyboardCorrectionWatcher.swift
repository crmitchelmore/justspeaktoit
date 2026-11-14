import Foundation

/// What the keyboard can read of the field it is open in, at one moment.
public struct KeyboardDocumentReads: Equatable, Sendable {
    public let documentIdentifier: UUID
    public let isSecureField: Bool
    public let before: String?
    public let selected: String?
    public let after: String?

    public init(
        documentIdentifier: UUID, isSecureField: Bool, before: String?, selected: String? = nil, after: String?
    ) {
        self.documentIdentifier = documentIdentifier
        self.isSecureField = isSecureField
        self.before = before
        self.selected = selected
        self.after = after
    }
}

/// Watches one transcript the iOS keyboard inserted, so an edit the user makes
/// afterwards can be learned (F48, #1651).
///
/// A keyboard extension only hears about the field while it is the active
/// keyboard. Edits happen on another keyboard, so the watch remembers the text
/// either side of the insertion, waits for this keyboard to go away, and
/// compares when it comes back: the words now between the remembered context
/// are the edited transcript. Only the changed words leave the watcher.
///
/// Pure state with an injected clock so it is testable without UIKit; the
/// keyboard owns one per process.
public struct KeyboardCorrectionWatcher: Sendable {
    /// How long after an insertion an edit still counts as a correction of it.
    public static let maximumAge: TimeInterval = 10 * 60

    private struct Watch: Sendable {
        let original: String
        let documentIdentifier: UUID
        let insertedAt: Date
        var context: CorrectionContext?
        var isArmed = false
    }

    private var watch: Watch?

    public init() {}

    public var isWatching: Bool { watch != nil }
    public var isArmed: Bool { watch?.isArmed == true }

    /// A transcript just reached `documentIdentifier`. `before` and `after` are
    /// the proxy's reads straight afterwards; `before` must end with the text.
    /// Any earlier watch is dropped: the new text may have landed inside it.
    public mutating func didInsert(
        _ text: String, documentIdentifier: UUID, at date: Date, before: String?, after: String?
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= AutoCorrectionLearningPolicy.maximumUTF16Units else {
            watch = nil
            return
        }
        watch = Watch(
            original: text,
            documentIdentifier: documentIdentifier,
            insertedAt: date,
            context: Self.context(for: text, before: before, after: after)
        )
    }

    /// A host callback while this keyboard is still on screen. Completes a
    /// context the proxy could not read straight after the insertion.
    public mutating func documentChanged(documentIdentifier: UUID, before: String?, after: String?) {
        guard var current = watch, !current.isArmed, current.context == nil,
              current.documentIdentifier == documentIdentifier else { return }
        current.context = Self.context(for: current.original, before: before, after: after)
        watch = current
    }

    /// This keyboard went away; the user can now edit with another one.
    public mutating func keyboardDidDisappear() {
        guard var current = watch else { return }
        guard current.context != nil else {
            watch = nil
            return
        }
        current.isArmed = true
        watch = current
    }

    /// The user turned learning off: nothing is compared.
    public mutating func reset() {
        watch = nil
    }

    /// This keyboard is back. Reads the field around the caret and returns the
    /// word changes made to the transcript, ending the watch once it has an
    /// answer. Returns `[]` and keeps waiting while the proxy has nothing to
    /// read yet, or while a different field's text cannot place the transcript
    /// (the user may still return to the first one).
    public mutating func sample(_ document: KeyboardDocumentReads, now: Date) -> [WordChange] {
        guard let current = watch, current.isArmed else { return [] }
        let sameDocument = current.documentIdentifier == document.documentIdentifier
        guard let context = current.context,
              now.timeIntervalSince(current.insertedAt) <= Self.maximumAge,
              now >= current.insertedAt else {
            watch = nil
            return []
        }
        if document.isSecureField {
            if sameDocument { watch = nil }
            return []
        }
        let text = (document.before ?? "") + (document.selected ?? "") + (document.after ?? "")
        guard !text.isEmpty else { return [] }
        // The proxy never says whether a read stopped at the field's edge or at
        // its own limit, so treat both reads as reaching the edges. A context
        // remembered as "at the start" must then still begin the read, which
        // keeps an uncertain placement from being learned.
        let window = CorrectionTextWindow(text: text, reachesStart: true, reachesEnd: true)
        guard let span = CorrectionSpan.locate(in: window, context: context) else {
            if sameDocument { watch = nil }
            return []
        }
        watch = nil
        guard span != current.original else { return [] }
        return WordDiffer.findChanges(original: current.original, edited: span)
    }

    private static func context(for text: String, before: String?, after: String?) -> CorrectionContext? {
        guard let before, before.hasSuffix(text) else { return nil }
        return .of(before: String(before.dropLast(text.count)), after: after ?? "")
    }
}
