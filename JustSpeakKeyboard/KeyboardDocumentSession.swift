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

        private static func scalarExact(_ lhs: String?, _ rhs: String?) -> Bool {
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
    }

    func anchorIsCurrent() -> Bool {
        guard let expectedSnapshot else { return false }
        return readSnapshot() == expectedSnapshot
    }

    func apply(_ edit: KeyboardTranscriptEdit) -> EditResult {
        guard anchorIsCurrent() else { return .anchorLost }

        for _ in 0..<edit.deleteCount {
            guard deleteOneCharacter() else { return .anchorLost }
        }

        var insertion = edit.insertion
        if !insertion.isEmpty, !separatorInserted, let pendingSeparator {
            insertion = pendingSeparator + insertion
            separatorInserted = true
        }
        if !insertion.isEmpty {
            insertText(insertion)
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
    }

    /// Handles both known `UITextDocumentProxy` behaviours: deleting a whole
    /// grapheme cluster or deleting one Unicode scalar at a time. Scalar-wise
    /// progress continues only while the complete bounded context is exact.
    private func deleteOneCharacter() -> Bool {
        guard let original = expectedSnapshot,
              let beforeInput = original.beforeInput,
              let character = beforeInput.last else {
            return false
        }

        let expectedWhole = Snapshot(
            beforeInput: String(beforeInput.dropLast()),
            afterInput: original.afterInput
        )
        deleteBackward()
        var current = readSnapshot()
        if current == expectedWhole {
            expectedSnapshot = current
            return true
        }

        let scalarCount = character.unicodeScalars.count
        guard scalarCount > 1 else { return false }

        var removedScalars = 1
        while removedScalars < scalarCount,
              current == scalarProgressSnapshot(
                  original: original,
                  beforeInput: beforeInput,
                  removedScalars: removedScalars
              ) {
            deleteBackward()
            removedScalars += 1
            current = readSnapshot()
            if current == expectedWhole {
                expectedSnapshot = current
                return true
            }
        }

        // A proven partial scalar deletion can be restored exactly before the
        // run is paused. Unknown host outcomes are never followed by an insert.
        if removedScalars < scalarCount,
           current == scalarProgressSnapshot(
               original: original,
               beforeInput: beforeInput,
               removedScalars: removedScalars
           ) {
            let removedSuffix = String(beforeInput.unicodeScalars.suffix(removedScalars))
            insertText(removedSuffix)
            current = readSnapshot()
        }
        expectedSnapshot = current
        return false
    }

    private func scalarProgressSnapshot(
        original: Snapshot,
        beforeInput: String,
        removedScalars: Int
    ) -> Snapshot {
        Snapshot(
            beforeInput: String(beforeInput.unicodeScalars.dropLast(removedScalars)),
            afterInput: original.afterInput
        )
    }
}
