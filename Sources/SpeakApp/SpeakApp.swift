import SwiftUI
import AppKit
// @Implement: This file should create call out to wireup to create all dependnecies and then call out setup the main app view 
@main
struct SpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Speak") {
            ContentView()
        }
        .defaultSize(width: 480, height: 320)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Hello, Speak")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("You're ready to build a macOS SwiftUI app.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

#Preview {
    ContentView()
}
