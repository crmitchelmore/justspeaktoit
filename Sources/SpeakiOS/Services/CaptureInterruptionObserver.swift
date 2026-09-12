#if os(iOS)
import AVFoundation
import SpeakCore

extension CaptureDisruptionObserver {
    /// Each live capture subscribes independently; stop/cancel retires queued events.
    /// An end notification, including shouldResume, never restarts capture.
    func observeAudioInterruption(onDisruption: @escaping @MainActor () -> Void) {
        observe(
            AVAudioSession.interruptionNotification,
            object: nil,
            matches: { notification in
                notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    == AVAudioSession.InterruptionType.began.rawValue
            },
            isUsable: { false },
            onDisruption: onDisruption
        )
    }
}
#endif
