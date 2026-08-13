import Foundation

/// The app-process entry point for "start/stop a recording", whoever asked:
/// the on-screen record button, the Double Tap gesture, or the watch-face
/// complication via `StartWatchRecordingIntent`.
///
/// Owns the single recorder instance so an intent performed while the UI is
/// not on screen toggles the same recording the UI shows.
@MainActor
final class WatchRecordingCoordinator {
    static let shared = WatchRecordingCoordinator()

    let recorder = WatchAudioRecorder()
    let store = WatchCaptureStore.shared
    private let toggleSerialiser = WatchRecordingToggleSerialiser()

    private init() {}

    /// Starts a recording, or stops the one in progress.
    func toggleRecording() async {
        await self.toggleSerialiser.run {
            await self.recorder.toggle(store: self.store)
        }
    }

    /// Performs a tap that was made on the watch face while the app was not
    /// running. Called when the app becomes active; stale requests are dropped
    /// by `WatchRecordingRequest.consume`.
    func performPendingWatchFaceRequest() async {
        guard WatchRecordingRequest.consume() != nil else { return }
        await self.toggleRecording()
    }
}
