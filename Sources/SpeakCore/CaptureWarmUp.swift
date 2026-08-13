import Foundation

// MARK: - Capture warm-up (issue #663)

/// Identity of the capture environment a staged (pre-warmed) recorder was built
/// for.
///
/// Pre-warming trades a small amount of idle work for a faster
/// hotkey→capture path, but a staged recorder is only reusable while the
/// environment it was built for still holds. Everything that can invalidate a
/// staged recorder lives in this value, so "is the staged recorder still good?"
/// is a single equality check.
///
/// `requiresDefaultDeviceSwitch` deserves a note: on macOS the app honours a
/// preferred input device by temporarily changing the *system* default input at
/// session start. A recorder staged before that switch would capture from the
/// wrong device, and switching the system default while the user is idle would
/// be user-hostile. So a session that needs the switch is simply not eligible
/// for warm-up and pays the cold path.
public struct CaptureWarmContext: Equatable, Sendable {
    /// UID of the device the next session will capture from, when known.
    public let inputDeviceUID: String?
    /// Directory the staged audio file is created in.
    public let recordingsDirectoryPath: String
    /// Stable identifier for the encoder settings (format, rate, channels, bitrate).
    public let encoderProfileID: String
    /// Whether session start will have to change the system default input device.
    public let requiresDefaultDeviceSwitch: Bool
    /// Whether microphone permission is already granted. Staging a recorder
    /// must never be the thing that triggers a permission prompt, so warm-up
    /// waits until the user has granted access through a real session.
    public let microphonePermissionGranted: Bool

    public init(
        inputDeviceUID: String?,
        recordingsDirectoryPath: String,
        encoderProfileID: String,
        requiresDefaultDeviceSwitch: Bool,
        microphonePermissionGranted: Bool
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.recordingsDirectoryPath = recordingsDirectoryPath
        self.encoderProfileID = encoderProfileID
        self.requiresDefaultDeviceSwitch = requiresDefaultDeviceSwitch
        self.microphonePermissionGranted = microphonePermissionGranted
    }

    /// Whether a recorder may be staged for this environment at all.
    public var isWarmable: Bool {
        guard self.microphonePermissionGranted else { return false }
        guard !self.requiresDefaultDeviceSwitch else { return false }
        guard self.inputDeviceUID != nil else { return false }
        return !self.recordingsDirectoryPath.isEmpty
    }
}

/// Where the staged recorder currently stands.
public enum CaptureWarmPhase: Equatable, Sendable {
    /// Nothing staged.
    case cold
    /// A recorder is being staged for this context.
    case warming(CaptureWarmContext)
    /// A recorder is staged and ready to be claimed by the next session.
    case ready(CaptureWarmContext)
}

/// What the owner should do to the staged recorder after a state transition.
public enum CaptureWarmAction: Equatable, Sendable {
    case none
    /// Stage a recorder for this context (create + prepare, never record).
    case prepare(CaptureWarmContext)
    /// Tear the staged recorder down and delete the file it created.
    case discard
    /// Tear the stale staged recorder down, then stage one for this context.
    case discardThenPrepare(CaptureWarmContext)
}

/// Warm-state machine for the capture start path.
///
/// Pure logic: it decides *when* a recorder should be staged, discarded, or
/// re-staged, and never touches AVFoundation. Every trigger — idle after a
/// session, audio route change, device selection change, permission change,
/// preference toggle — funnels through ``reconcile(with:enabled:)``, so there
/// is exactly one place where the rules live.
public struct CaptureWarmStateMachine: Equatable, Sendable {
    public private(set) var phase: CaptureWarmPhase

    public init() {
        self.phase = .cold
    }

    /// The context a staged recorder is ready for, if any.
    public var readyContext: CaptureWarmContext? {
        switch self.phase {
        case .ready(let context):
            return context
        case .cold, .warming:
            return nil
        }
    }

    /// Brings the machine in line with the current environment.
    ///
    /// - Parameters:
    ///   - context: the environment the *next* session would start in.
    ///   - enabled: the user's pre-warm preference.
    /// - Returns: the work the owner must perform to match the new state.
    public mutating func reconcile(
        with context: CaptureWarmContext,
        enabled: Bool
    ) -> CaptureWarmAction {
        guard enabled, context.isWarmable else {
            return self.reset()
        }

        switch self.phase {
        case .cold:
            self.phase = .warming(context)
            return .prepare(context)
        case .warming(let staged):
            guard staged != context else { return .none }
            self.phase = .warming(context)
            return .discardThenPrepare(context)
        case .ready(let staged):
            guard staged != context else { return .none }
            self.phase = .warming(context)
            return .discardThenPrepare(context)
        }
    }

    /// Records that staging finished. Returns `false` when the result is stale
    /// (the environment moved on while the recorder was being staged), in which
    /// case the caller must throw the freshly staged recorder away.
    @discardableResult
    public mutating func markReady(_ context: CaptureWarmContext) -> Bool {
        guard case .warming(let pending) = self.phase, pending == context else {
            return false
        }
        self.phase = .ready(context)
        return true
    }

    /// Records that staging failed. Only clears state when the failure belongs
    /// to the context currently being staged.
    public mutating func markFailed(_ context: CaptureWarmContext) {
        guard case .warming(let pending) = self.phase, pending == context else { return }
        self.phase = .cold
    }

    /// Hands the staged recorder to a starting session. Returns `false` when
    /// nothing usable is staged, and the session must take the cold path.
    public mutating func claim(for context: CaptureWarmContext) -> Bool {
        guard case .ready(let staged) = self.phase, staged == context else {
            return false
        }
        self.phase = .cold
        return true
    }

    /// Drops any staged state. Returns the teardown the owner owes.
    public mutating func reset() -> CaptureWarmAction {
        switch self.phase {
        case .cold:
            return .none
        case .warming, .ready:
            self.phase = .cold
            return .discard
        }
    }
}
