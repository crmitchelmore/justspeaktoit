import Foundation

/// Classifies one shortcut's presses and releases into hold, tap and double-tap
/// gestures. It states the macOS `GestureDetector` rules as a pure function of
/// explicit timestamps, so a host drives it with its own clock and timer and a
/// test can replay an exact timeline:
///
/// - A press while the key is already down is ignored.
/// - A press cancels a pending single tap and arms the hold deadline. If the
///   key is still down when it elapses, `holdStart` fires, and the release
///   fires `holdEnd`.
/// - A release within the double-tap window of the previous release, including
///   the release that ended a hold, fires `doubleTap` and starts a short tap
///   cooldown. A double tap closer than the duplicate gap to the previous one
///   is dropped.
/// - Any other release outside the cooldown arms the single-tap deadline,
///   which fires `singleTap` unless a press arrives first.
/// - `reset` forgets partial gestures and ends a hold in progress with a
///   balanced `holdEnd`, because nothing will report its release any more.
///
/// "No earlier release" is absent state rather than time zero, so timelines
/// may start at any timestamp. At most one deadline is pending: the host arms
/// a timer whenever `deadline` changes and reports its expiry through
/// `deadlineReached(at:)`. An expiry more than `timerTolerance` early, such as
/// a stale timer, is ignored and leaves the deadline pending.
public struct HotKeyGestureMachine: Equatable, Sendable {
    public enum Gesture: String, CaseIterable, Sendable {
        case holdStart
        case holdEnd
        case singleTap
        case doubleTap
    }

    public enum DeadlineKind: Equatable, Sendable {
        case hold
        case singleTap
    }

    public struct Deadline: Equatable, Sendable {
        public let kind: DeadlineKind
        public let time: TimeInterval
    }

    /// Window-message timers can fire a little before the host's own clock
    /// reaches the deadline they were armed for.
    public static let timerTolerance: TimeInterval = 0.02

    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    public private(set) var isKeyDown = false
    /// `holdStart` fired and its `holdEnd` is still due.
    public private(set) var isHoldInProgress = false
    public private(set) var deadline: Deadline?
    private var lastRelease: TimeInterval?
    private var lastDoubleTap: TimeInterval?
    private var tapCooldownEnd: TimeInterval?

    public init(
        holdThreshold: TimeInterval = HotKeyGestureTiming.defaultHoldThreshold,
        doubleTapWindow: TimeInterval = HotKeyGestureTiming.defaultDoubleTapWindow
    ) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func keyDown(at now: TimeInterval) -> [Gesture] {
        guard !isKeyDown else { return [] }
        isKeyDown = true
        isHoldInProgress = false
        // Replacing the deadline also cancels a pending single tap.
        deadline = Deadline(kind: .hold, time: now + holdThreshold)
        return []
    }

    public mutating func keyUp(at now: TimeInterval) -> [Gesture] {
        guard isKeyDown else { return [] }
        isKeyDown = false
        // While the key is down the only possible deadline is the hold's.
        deadline = nil
        let previousRelease = lastRelease
        lastRelease = now
        if isHoldInProgress {
            isHoldInProgress = false
            return [.holdEnd]
        }
        if let previousRelease, now - previousRelease <= doubleTapWindow {
            tapCooldownEnd = now + min(doubleTapWindow, HotKeyGestureTiming.doubleTapCooldownCap)
            return doubleTap(at: now)
        }
        if let tapCooldownEnd, now < tapCooldownEnd { return [] }
        deadline = Deadline(kind: .singleTap, time: now + doubleTapWindow)
        return []
    }

    public mutating func deadlineReached(at now: TimeInterval) -> [Gesture] {
        guard let pending = deadline, now + Self.timerTolerance >= pending.time else { return [] }
        deadline = nil
        switch pending.kind {
        case .hold:
            guard isKeyDown, !isHoldInProgress else { return [] }
            isHoldInProgress = true
            return [.holdStart]
        case .singleTap:
            return [.singleTap]
        }
    }

    public mutating func reset() -> [Gesture] {
        let endsHold = isHoldInProgress
        self = HotKeyGestureMachine(holdThreshold: holdThreshold, doubleTapWindow: doubleTapWindow)
        return endsHold ? [.holdEnd] : []
    }

    private mutating func doubleTap(at now: TimeInterval) -> [Gesture] {
        let gap = HotKeyGestureTiming.duplicateDoubleTapGap(window: doubleTapWindow)
        if let lastDoubleTap, now - lastDoubleTap < gap { return [] }
        lastDoubleTap = now
        return [.doubleTap]
    }
}
