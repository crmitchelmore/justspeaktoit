import Foundation

/// The keyboard extension's side of learned corrections (F48, #1651): watches
/// each transcript it inserts and posts the words the user changed to the App
/// Group inbox the containing app records from.
///
/// One per extension process, because iOS can rebuild the input view
/// controller (and its view model) on every appearance while the edit being
/// watched happened between two of them.
@MainActor
public final class KeyboardCorrectionObserver {
    public static let shared = KeyboardCorrectionObserver()

    private var watcher = KeyboardCorrectionWatcher()
    private let store: KeyboardCorrectionStore
    private let now: () -> Date

    public init(store: KeyboardCorrectionStore = .shared, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public var isWatching: Bool { watcher.isWatching }

    /// A transcript just reached the field. Password fields and a disabled
    /// setting are never watched.
    public func didInsert(_ text: String, into document: KeyboardDocumentReads) {
        guard !document.isSecureField, store.isLearningEnabled else {
            watcher.reset()
            return
        }
        watcher.didInsert(
            text, documentIdentifier: document.documentIdentifier, at: now(),
            before: document.before, after: document.after
        )
    }

    /// This keyboard appeared again: compare the field with the watched text.
    public func keyboardDidAppear(_ document: KeyboardDocumentReads) {
        sampleIfArmed(document)
    }

    /// A host text or selection callback while this keyboard is on screen.
    public func documentChanged(_ document: KeyboardDocumentReads) {
        if watcher.isArmed {
            sampleIfArmed(document)
        } else {
            watcher.documentChanged(
                documentIdentifier: document.documentIdentifier, before: document.before, after: document.after
            )
        }
    }

    /// This keyboard went away, so the user can edit with another one.
    public func keyboardDidDisappear() {
        watcher.keyboardDidDisappear()
    }

    private func sampleIfArmed(_ document: KeyboardDocumentReads) {
        guard watcher.isArmed else { return }
        guard store.isLearningEnabled else {
            watcher.reset()
            return
        }
        let date = now()
        store.append(watcher.sample(document, now: date), observedAt: date)
    }
}
