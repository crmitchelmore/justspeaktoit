import AppKit
import SwiftUI

@main
struct SpeakApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var environment = WireUp.bootstrap()

  var body: some Scene {
    WindowGroup("Speak") {
      MainView()
        .environmentObject(environment)
        .environmentObject(environment.settings)
        .environmentObject(environment.history)
        .environmentObject(environment.personalLexicon)
        .environmentObject(environment.audioDevices)
    }
    .defaultSize(width: 1080, height: 720)
  }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.applicationIconImage = AppIconProvider.applicationIcon()
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
  }
}
