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
                    // A complication tap made while the app was not running
                    // leaves a request behind; perform it now that the audio
                    // session is available.
                    guard phase == .active else { return }
                    Task {
                        await WatchRecordingCoordinator.shared.performPendingWatchFaceRequest()
                    }
                }
        }
    }
}
