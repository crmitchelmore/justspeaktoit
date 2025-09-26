import AppKit
import SwiftUI

// @Implement: This file should create call out to wireup to create all dependnecies and then call out setup the main app view
@main
struct SpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = WireUp.bootstrap()

    var body: some Scene {
        WindowGroup("Speak") {
            MainView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
        }
        .defaultSize(width: 1080, height: 720)
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
