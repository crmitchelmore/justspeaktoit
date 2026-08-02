public enum KeyboardCorrectionPlan {
    /// Returns the number of user-perceived characters that can be deleted to
    /// undo the last insertion, but only while that exact text still precedes
    /// the cursor. This avoids deleting host-app text after the user edits or
    /// moves the insertion point.
    public static func undoDeletionCount(
        insertedText: String,
        documentContextBeforeInput: String?
    ) -> Int? {
        guard !insertedText.isEmpty,
              let documentContextBeforeInput,
              documentContextBeforeInput.hasSuffix(insertedText) else {
            return nil
        }
        return insertedText.count
    }
}
