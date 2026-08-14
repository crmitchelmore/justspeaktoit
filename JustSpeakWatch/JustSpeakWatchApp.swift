import SwiftUI

@main
struct JustSpeakWatchApp: App {
    // `WatchCaptureStore.shared` manages its own lifetime, so the view
    // observes it rather than owning it.
    @ObservedObject private var captureStore = WatchCaptureStore.shared
    @StateObject private var recorder = WatchAudioRecorder()

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
                }
        }
    }
}
