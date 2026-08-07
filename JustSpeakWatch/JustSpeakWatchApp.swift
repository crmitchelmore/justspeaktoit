import SwiftUI

@main
struct JustSpeakWatchApp: App {
    @StateObject private var captureStore = WatchCaptureStore.shared
    @StateObject private var recorder = WatchAudioRecorder()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(captureStore)
                .environmentObject(recorder)
                .onAppear {
                    captureStore.activate()
                }
        }
    }
}
