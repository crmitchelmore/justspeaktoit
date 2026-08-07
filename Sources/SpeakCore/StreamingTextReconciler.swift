import Foundation

/// The minimal edit that turns one live-transcript snapshot into the next:
/// keep the longest common (stable) prefix, replace the differing tail.
///
/// Offsets and lengths are expressed in UTF-16 code units because that is the
/// unit macOS accessibility text ranges (`kAXSelectedTextRange`) use, but the
/// common prefix is computed on grapheme clusters so a replacement boundary can
/// never split an emoji, flag, or combining-mark sequence.
public struct StreamingTextDiff: Equatable, Sendable {
    /// UTF-16 offset from the start of the previously inserted text where the
    /// replacement begins. Everything before it is the stable prefix.
    public let replaceLocationUTF16: Int
    /// UTF-16 length of the old tail being replaced (0 for pure appends).
    public let replaceLengthUTF16: Int
    /// Text that replaces the old tail (empty for pure retractions).
    public let replacement: String

    public init(replaceLocationUTF16: Int, replaceLengthUTF16: Int, replacement: String) {
        self.replaceLocationUTF16 = replaceLocationUTF16
        self.replaceLengthUTF16 = replaceLengthUTF16
        self.replacement = replacement
    }

    /// True when the snapshots are identical and no accessibility write is needed.
    public var isNoOp: Bool {
        self.replaceLengthUTF16 == 0 && self.replacement.isEmpty
    }
}

/// Computes stable-prefix/tail diffs between successive live-transcript
/// snapshots so streaming insertion can patch only the unstable tail of what
/// it already typed into the target app.
public enum StreamingTextReconciler {
    /// The minimal tail replacement that transforms `current` into `target`.
    ///
    /// Handles every provider behaviour: pure prefix growth (append), tail
    /// retraction (target shorter), and corrections that rewrite earlier words
    /// (stable prefix shrinks). The boundary always falls on a grapheme-cluster
    /// edge in both strings.
    public static func diff(from current: String, to target: String) -> StreamingTextDiff {
        var currentIndex = current.startIndex
        var targetIndex = target.startIndex
        while currentIndex < current.endIndex,
              targetIndex < target.endIndex,
              current[currentIndex] == target[targetIndex] {
            current.formIndex(after: &currentIndex)
            target.formIndex(after: &targetIndex)
        }
        return StreamingTextDiff(
            replaceLocationUTF16: current[..<currentIndex].utf16.count,
            replaceLengthUTF16: current[currentIndex...].utf16.count,
            replacement: String(target[targetIndex...])
        )
    }

    /// Applies `diff` to `current`, returning the reconstructed text. Used by
    /// tests as the ground-truth inverse of `diff(from:to:)`, and by callers
    /// that need to know what a target field should contain after a patch.
    public static func apply(_ diff: StreamingTextDiff, to current: String) -> String? {
        let utf16 = current.utf16
        guard diff.replaceLocationUTF16 >= 0,
              diff.replaceLengthUTF16 >= 0,
              diff.replaceLocationUTF16 + diff.replaceLengthUTF16 <= utf16.count
        else { return nil }
        guard
            let start = utf16.index(
                utf16.startIndex, offsetBy: diff.replaceLocationUTF16
            ).samePosition(in: current),
            let end = utf16.index(
                utf16.startIndex, offsetBy: diff.replaceLocationUTF16 + diff.replaceLengthUTF16
            ).samePosition(in: current)
        else { return nil }
        return current.replacingCharacters(in: start..<end, with: diff.replacement)
    }
}
