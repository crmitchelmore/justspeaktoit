import Foundation

/// The text either side of an inserted transcript when it was inserted. An
/// empty side that was read short means the insertion touched that end of the
/// field. Mirrors Android's `CorrectionContext` (#1717).
public struct CorrectionContext: Equatable, Sendable {
    public let before: String
    public let after: String
    public let atStart: Bool
    public let atEnd: Bool

    public init(before: String, after: String, atStart: Bool, atEnd: Bool) {
        self.before = before
        self.after = after
        self.atStart = atStart
        self.atEnd = atEnd
    }

    /// `before` and `after` as read, at most `CorrectionSpan.contextLength`
    /// characters each.
    public static func of(before: String, after: String) -> CorrectionContext {
        let length = CorrectionSpan.contextLength
        return CorrectionContext(
            before: String(before.suffix(length)),
            after: String(after.prefix(length)),
            atStart: before.count < length,
            atEnd: after.count < length
        )
    }
}

/// Text read around the cursor later, and whether the reads reached the start
/// and end of the field.
public struct CorrectionTextWindow: Equatable, Sendable {
    public let text: String
    public let reachesStart: Bool
    public let reachesEnd: Bool

    public init(text: String, reachesStart: Bool, reachesEnd: Bool) {
        self.text = text
        self.reachesStart = reachesStart
        self.reachesEnd = reachesEnd
    }
}

/// Finds what became of an inserted transcript: the text now between the
/// context remembered either side of it. Any doubt (a context missing, found
/// more than once, or a span over the size limit) returns `nil`, so an edit is
/// never attributed to the wrong text. The Android keyboard runs the same
/// algorithm (`CorrectionSpan.kt`).
public enum CorrectionSpan {
    /// Characters remembered either side of an insertion.
    public static let contextLength = 32

    public static func locate(
        in window: CorrectionTextWindow,
        context: CorrectionContext,
        maxUTF16Length: Int = AutoCorrectionLearningPolicy.maximumUTF16Units
    ) -> String? {
        let text = window.text
        let start: String.Index
        if context.atStart {
            guard window.reachesStart, text.hasPrefix(context.before) else { return nil }
            start = text.index(text.startIndex, offsetBy: context.before.count)
        } else {
            guard let range = uniqueRange(of: context.before, in: text) else { return nil }
            start = range.upperBound
        }
        let end: String.Index
        if context.atEnd {
            guard window.reachesEnd, text.hasSuffix(context.after) else { return nil }
            end = text.index(text.endIndex, offsetBy: -context.after.count)
        } else {
            guard let range = uniqueRange(of: context.after, in: text) else { return nil }
            end = range.lowerBound
        }
        guard start <= end else { return nil }
        let span = text[start..<end]
        guard span.utf16.count <= maxUTF16Length else { return nil }
        return String(span)
    }

    /// The range of `needle` when it occurs exactly once, overlaps included;
    /// `nil` otherwise.
    private static func uniqueRange(of needle: String, in text: String) -> Range<String.Index>? {
        guard !needle.isEmpty, let first = text.range(of: needle, options: .literal) else { return nil }
        let next = text.index(after: first.lowerBound)
        if text.range(of: needle, options: .literal, range: next..<text.endIndex) != nil { return nil }
        return first
    }
}
