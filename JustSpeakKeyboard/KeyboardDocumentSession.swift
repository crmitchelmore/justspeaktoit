import Foundation
import SpeakCore

/// Owns the bounded host-document region touched by one direct dictation run.
/// Every replacement is conditional on the cursor context still matching the
/// previous extension-authored edit.
@MainActor
final class KeyboardDocumentSession {
    struct Snapshot: Equatable {
        let beforeInput: String?
        let afterInput: String?

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            Self.scalarExact(lhs.beforeInput, rhs.beforeInput)
                && Self.scalarExact(lhs.afterInput, rhs.afterInput)
        }

        fileprivate static func scalarExact(_ lhs: String?, _ rhs: String?) -> Bool {
            switch (lhs, rhs) {
            case let (.some(lhs), .some(rhs)):
                lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
            case (.none, .none):
                true
            default:
                false
            }
        }
    }

    enum EditResult: Equatable {
        case applied
        case anchorLost
    }

    private let insertText: (String) -> Void
    private let deleteBackward: () -> Void
    private let readSnapshot: () -> Snapshot

    private var expectedSnapshot: Snapshot?
    private var pendingSeparator: String?
    private var separatorInserted = false
    private var authoredText = ""

    init(
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        contextBeforeInput: @escaping () -> String?,
        contextAfterInput: @escaping () -> String?
    ) {
        self.insertText = insertText
        self.deleteBackward = deleteBackward
        self.readSnapshot = {
            Snapshot(
                beforeInput: contextBeforeInput(),
                afterInput: contextAfterInput()
            )
        }
    }

    func begin() {
        let snapshot = readSnapshot()
        expectedSnapshot = snapshot
        pendingSeparator = KeyboardTranscriptStreamer.leadingSeparator(
            contextBeforeInput: snapshot.beforeInput
        )
        separatorInserted = false
        authoredText = ""
    }

    func anchorIsCurrent() -> Bool {
        guard let expectedSnapshot else { return false }
        return readSnapshot() == expectedSnapshot
    }

    func apply(_ edit: KeyboardTranscriptEdit) -> EditResult {
        guard anchorIsCurrent() else { return .anchorLost }
        guard edit.deleteCount <= authoredText.count,
              contextContainsAuthoredSuffix() else {
            return .anchorLost
        }

        for _ in 0..<edit.deleteCount {
            guard deleteOneCharacter() else { return .anchorLost }
            authoredText.removeLast()
        }

        var insertion = edit.insertion
        if !insertion.isEmpty, !separatorInserted, let pendingSeparator {
            insertion = pendingSeparator + insertion
            separatorInserted = true
        }
        if !insertion.isEmpty {
            insertText(insertion)
            authoredText += edit.insertion
            expectedSnapshot = readSnapshot()
        }
        return .applied
    }

    /// Removes only the session-owned separator. It is called for an empty
    /// final result; permission/startup failures never insert the separator.
    func removeSeparatorIfTranscriptIsEmpty() -> EditResult {
        guard separatorInserted else { return .applied }
        guard anchorIsCurrent(), expectedSnapshot?.beforeInput?.last == " " else {
            return .anchorLost
        }
        guard deleteOneCharacter() else { return .anchorLost }
        separatorInserted = false
        return .applied
    }

    func invalidate() {
        expectedSnapshot = nil
        pendingSeparator = nil
        separatorInserted = false
        authoredText = ""
    }

    /// Handles both known `UITextDocumentProxy` behaviours: deleting a whole
    /// grapheme cluster or deleting one Unicode scalar at a time. Scalar-wise
    /// progress continues only while the unchanged context remains provable.
    private func deleteOneCharacter() -> Bool {
        guard let original = expectedSnapshot,
              let beforeInput = original.beforeInput,
              let character = beforeInput.last else {
            return false
        }

        let scalarCount = character.unicodeScalars.count
        deleteBackward()
        var current = readSnapshot()
        if current.matchesRemoval(of: scalarCount, from: original) {
            expectedSnapshot = current
            return true
        }

        guard scalarCount > 1, current.matchesRemoval(of: 1, from: original) else {
            expectedSnapshot = current
            return false
        }

        var removedScalars = 1
        while removedScalars < scalarCount {
            deleteBackward()
            removedScalars += 1
            current = readSnapshot()
            if current.matchesRemoval(of: scalarCount, from: original) {
                expectedSnapshot = current
                return true
            }
            guard current.matchesRemoval(of: removedScalars, from: original) else { break }
        }

        // A proven partial scalar deletion can be restored exactly before the
        // run is paused. Unknown host outcomes are never followed by an insert.
        if removedScalars < scalarCount,
           current.matchesRemoval(of: removedScalars, from: original) {
            let removedSuffix = String(beforeInput.unicodeScalars.suffix(removedScalars))
            insertText(removedSuffix)
            current = readSnapshot()
        }
        expectedSnapshot = current
        return false
    }

    private func contextContainsAuthoredSuffix() -> Bool {
        guard !authoredText.isEmpty else { return true }
        guard let beforeInput = expectedSnapshot?.beforeInput else { return false }
        let visibleCount = min(beforeInput.count, authoredText.count)
        return beforeInput.suffix(visibleCount).elementsEqual(authoredText.suffix(visibleCount))
    }
}

private extension KeyboardDocumentSession.Snapshot {
    /// Host apps may keep `documentContextBeforeInput` at a fixed bound, so a
    /// successful delete can reveal older text at the front instead of simply
    /// shortening the context. The unchanged suffix and after-context still
    /// prove that the requested number of scalars was removed at the cursor.
    func matchesRemoval(of scalarCount: Int, from original: Self) -> Bool {
        guard scalarCount > 0,
              let originalBefore = original.beforeInput,
              let currentBefore = beforeInput,
              Snapshot.scalarExact(afterInput, original.afterInput) else {
            return false
        }
        let originalScalars = originalBefore.unicodeScalars
        let currentScalars = currentBefore.unicodeScalars
        guard scalarCount <= originalScalars.count else { return false }
        let expectedSuffix = originalScalars.dropLast(scalarCount)
        guard currentScalars.count >= expectedSuffix.count,
              currentScalars.count <= originalScalars.count else {
            return false
        }
        return currentScalars.suffix(expectedSuffix.count).elementsEqual(expectedSuffix)
    }
}
