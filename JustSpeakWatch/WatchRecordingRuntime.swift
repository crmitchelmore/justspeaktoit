import AVFoundation
import Foundation

/// Keeps a watch recording running once the wrist drops and the screen goes
/// off, and reports when watchOS is about to take that runtime away.
///
/// ## Why the audio background mode, and not `WKExtendedRuntimeSession`
///
/// watchOS offers two ways to keep running past the screen turning off, and
/// only one of them is legitimate for a dictation app:
///
/// 1. **The `audio` background mode** (`UIBackgroundModes` in the watch app's
///    Info.plist — see `Project.swift`). An `AVAudioSession` activated while
///    the app is in the foreground keeps the app alive for as long as audio is
///    actually flowing, including with the wrist down, the screen off, and the
///    user back on the watch face. This is the mechanism this app uses.
/// 2. **`WKExtendedRuntimeSession`**, which has no "recording" session type.
///    The only types are self care, mindfulness, physical therapy, smart alarm
///    and underwater depth, and Apple's guidance is explicit: *"Select a
///    session type based on the app's intended use — not based on the features
///    that the session provides."* Claiming `.mindfulness` or `.selfCare` to
///    buy runtime for dictation is exactly the misuse that guidance targets.
///    It would also buy nothing here: both are frontmost-only sessions that
///    invalidate with `.resignedFrontmost` the moment the user presses the
///    Digital Crown, whereas the audio background mode survives that. Apple's
///    own documentation closes the question — *"if your app plays audio during
///    the entire [...] session, there's no reason to use a
///    `WKExtendedRuntimeSession`. The background audio mode provides
///    additional runtime as long as the audio plays."*
///
/// The trade-off the audio background mode brings is that an interruption
/// (call, Siri, another audio app) cannot be recovered from while the app is
/// backgrounded — the audio session simply cannot be reactivated. That is why
/// this type reports interruptions as an end of runtime rather than trying to
/// resume: the recorder stops cleanly and the partial capture is queued for
/// the iPhone instead of being lost.
///
/// See: developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
/// and developer.apple.com/documentation/watchkit/playing-background-audio
@MainActor
final class WatchRecordingRuntime {
    /// Called when watchOS ends the runtime under an active recording. The
    /// recorder is expected to stop and hand whatever it captured to the
    /// capture queue.
    var onRuntimeEnd: ((WatchRecordingEndReason) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var activeRunID: UUID?

    /// Activates the audio session that grants the background runtime. Must be
    /// called while the app is frontmost — watchOS only allows a recording to
    /// *start* in the foreground, after which it may continue in the
    /// background.
    func begin() throws {
        let session = AVAudioSession.sharedInstance()
        // This app only records on watch; `.record` truthfully describes the
        // active hardware behaviour and still participates in background audio.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let runID = UUID()
        activeRunID = runID
        observeRuntimeLoss(runID: runID)
    }

    /// Releases the audio session and stops watching for runtime loss.
    func end() {
        activeRunID = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeRuntimeLoss(runID: UUID) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor in
                    guard self?.activeRunID == runID else { return }
                    self?.onRuntimeEnd?(.interrupted)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    guard self?.activeRunID == runID else { return }
                    self?.onRuntimeEnd?(.runtimeInvalidated(reason: nil))
                }
            }
        )
    }
}
