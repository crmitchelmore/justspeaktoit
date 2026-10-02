import Foundation

/// The recording HUD a desktop host floats at the bottom of the screen during
/// a dictation, modelled on the Mac's `HUDManager`: the same phases, wording,
/// per-phase clock and display durations, so Windows and Linux say what the
/// Mac says. Hosts draw it natively; each new phase restarts its clock, shown
/// as the Mac shows it (`07.24s`, then `01:07.24` past a minute).
public struct DesktopHUDState: Equatable, Sendable {
    /// Raw values cross the hosts' C ABI; keep them stable.
    public enum Phase: Int32, Sendable {
        case hidden = 0
        case recording = 1
        case transcribing = 2
        case postProcessing = 3
        case delivering = 4
        case success = 5
        case failure = 6

        public var isTerminal: Bool { self == .success || self == .failure }
    }

    public var phase: Phase
    public var headline: String
    public var subheadline: String?
    /// Words arriving from a live model while recording.
    public var liveText: String?

    /// How long a finished dictation stays up, as on the Mac.
    public static let successDisplayDuration: TimeInterval = 2.4
    public static let failureDisplayDuration: TimeInterval = 6.0

    public static let hidden = DesktopHUDState(phase: .hidden, headline: "")

    public init(phase: Phase, headline: String, subheadline: String? = nil, liveText: String? = nil) {
        self.phase = phase
        self.headline = headline
        self.subheadline = subheadline
        self.liveText = liveText
    }

    /// Whether the phase shows a running clock.
    public var showsClock: Bool { phase != .hidden && !phase.isTerminal }

    /// Seconds a terminal phase stays up before the HUD hides; nil otherwise.
    public var displayDuration: TimeInterval? {
        switch phase {
        case .success: return Self.successDisplayDuration
        case .failure: return Self.failureDisplayDuration
        default: return nil
        }
    }

    /// The HUD shows the latest words, so a long dictation sends only its tail.
    public static let liveTextLimit = 280

    public static func recording(profile: String?, liveText: String? = nil) -> DesktopHUDState {
        var tail = liveText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tail.count > liveTextLimit { tail = "…" + tail.suffix(liveTextLimit - 1) }
        return DesktopHUDState(
            phase: .recording, headline: "Recording",
            subheadline: profile.map { "Profile: \($0)" } ?? "Capturing audio",
            liveText: tail.isEmpty ? nil : tail
        )
    }

    public static func transcribing(live: Bool = false) -> DesktopHUDState {
        DesktopHUDState(
            phase: .transcribing, headline: "Transcribing",
            subheadline: live ? "Finishing live transcript" : "Preparing raw transcript"
        )
    }

    public static let postProcessing = DesktopHUDState(
        phase: .postProcessing, headline: "Post-processing", subheadline: "Cleaning up transcript"
    )

    public static func delivering(copying: Bool) -> DesktopHUDState {
        DesktopHUDState(
            phase: .delivering, headline: "Delivering",
            subheadline: copying ? "Copying to the clipboard" : "Pasting into target app"
        )
    }

    public static func success(_ message: String) -> DesktopHUDState {
        DesktopHUDState(phase: .success, headline: "Completed", subheadline: message)
    }

    public static func failure(_ message: String, headline: String = "Something went wrong") -> DesktopHUDState {
        DesktopHUDState(phase: .failure, headline: headline, subheadline: message)
    }
}
