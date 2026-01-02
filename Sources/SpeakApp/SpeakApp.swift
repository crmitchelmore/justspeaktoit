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
                .environmentObject(environment.tts)
                .environmentObject(environment.shortcuts)
                .onAppear {
                    appDelegate.environment = environment
                    environment.configureShortcutHandlers()
                    environment.installMenuBar()
                    environment.installDockMenu()
                    environment.installServices()
                    if #available(macOS 10.12.2, *) {
                        environment.installTouchBar()
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            SpeakCommands(environment: environment)
        }
    }
}

/// Custom menu commands for Speak.
struct SpeakCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Start/Stop Recording") {
                environment.main.toggleRecordingFromUI()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Speak Help") {
                if let url = URL(string: "https://github.com/speak-app/speak") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIconProvider.applicationIcon()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        environment?.createDockMenu()
    }

    // MARK: - Menu Action Handlers

    @objc func startStopRecording() {
        Task { @MainActor in
            environment?.main.toggleRecordingFromUI()
        }
    }

    @objc func speakSelectedText() {
        Task { @MainActor in
            guard let environment else { return }
            // Simulate Cmd+C to get selected text, then speak
            let pasteboard = NSPasteboard.general
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 100_000_000)

            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                _ = try? await environment.tts.synthesize(text: text)
            }
        }
    }

    @objc func speakClipboard() {
        Task { @MainActor in
            guard let environment else { return }
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                _ = try? await environment.tts.synthesize(text: text)
            }
        }
    }

    @objc func pauseResumeTTS() {
        Task { @MainActor in
            guard let environment else { return }
            if environment.tts.isPlaying {
                environment.tts.pause()
            } else {
                environment.tts.resume()
            }
        }
    }

    @objc func stopTTS() {
        Task { @MainActor in
            environment?.tts.stop()
        }
    }

    @objc func quickVoice1() {
        switchToQuickVoice(1)
    }

    @objc func quickVoice2() {
        switchToQuickVoice(2)
    }

    @objc func quickVoice3() {
        switchToQuickVoice(3)
    }

    private func switchToQuickVoice(_ index: Int) {
        Task { @MainActor in
            guard let environment else { return }
            let favorites = environment.settings.ttsFavoriteVoices
            let arrayIndex = index - 1
            if arrayIndex < favorites.count {
                environment.settings.defaultTTSVoice = favorites[arrayIndex]
            }
        }
    }

    @objc func showHistory() {
        Task { @MainActor in
            // Activate the app and show the history view
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            // Navigate to history tab would require additional navigation state
        }
    }

    @objc func openSettings() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            // Navigate to settings would require additional navigation state
        }
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard sender.representedObject as? UUID != nil else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            // Would need to navigate to specific history item
        }
    }
}

