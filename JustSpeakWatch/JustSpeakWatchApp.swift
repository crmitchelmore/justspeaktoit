import SwiftUI

@main
struct JustSpeakWatchApp: App {
    // `WatchCaptureStore.shared` and the coordinator's recorder manage their
    // own lifetime, so the view observes them rather than owning them. The
    // recorder must be the coordinator's: a complication tap toggles the same
    // recording the UI shows.
    @ObservedObject private var captureStore = WatchCaptureStore.shared
    @ObservedObject private var recorder = WatchRecordingCoordinator.shared.recorder
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(captureStore)
                .environmentObject(recorder)
                .onAppear {
                    captureStore.activate()
                }
                .task {
                    await recorder.recoverInterruptedCapture()
                    await WatchRecordingCoordinator.shared.performPendingWatchFaceRequest()
                }
                .onChange(of: scenePhase) { _, phase in
                    // The watchOS 10 fallback can leave a request while opening
                    // the app; perform it once the audio session is available.
                    // watchOS 11+ runs its AudioRecordingIntent headlessly.
                    guard phase == .active else { return }
                    Task {
                        await WatchRecordingCoordinator.shared.performPendingWatchFaceRequest()
                    }
                }
        }
    }
}
