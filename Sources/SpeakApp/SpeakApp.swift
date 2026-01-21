import AppKit
import SwiftUI

@main
struct SpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environmentHolder = EnvironmentHolder()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup("Just Speak to It") {
            Group {
                if let environment = environmentHolder.environment {
                    if hasCompletedOnboarding {
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
                    } else {
                        OnboardingView(
                            permissionsManager: environment.permissionsManager,
                            secureStorage: environment.secureStorage,
                            isComplete: $hasCompletedOnboarding
                        )
                        .onAppear {
                            appDelegate.environment = environment
                        }
                    }
                } else {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task {
                            environmentHolder.bootstrap()
                        }
                }
            }
            .tint(.brandAccent)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            if let environment = environmentHolder.environment {
                SpeakCommands(environment: environment)
            }
        }
    }
}

/// Holds the AppEnvironment and defers its creation until after SwiftUI's graph is ready.
@MainActor
final class EnvironmentHolder: ObservableObject {
    @Published var environment: AppEnvironment?

    func bootstrap() {
        guard environment == nil else { return }
        environment = WireUp.bootstrap()
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
            Button("Just Speak to It Help") {
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
        
        // Check if running from DMG and offer to move to Applications
        checkAndOfferDMGCleanup()
    }
    
    private func checkAndOfferDMGCleanup() {
        let bundlePath = Bundle.main.bundlePath
        
        // Check if running from a DMG (mounted volume that's not /Applications)
        if bundlePath.hasPrefix("/Volumes/") && !bundlePath.hasPrefix("/Applications") {
            // Running from DMG - suggest moving to Applications
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.showMoveToApplicationsAlert()
            }
        } else if bundlePath.hasPrefix("/Applications") {
            // Running from Applications - always check for mounted DMG on first launch of this session
            // This handles the case where user drags to Applications, then launches
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.checkForMountedDMG()
            }
        }
    }
    
    private func showMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "Just Speak to It is running from a disk image. Would you like to move it to your Applications folder for better performance?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        
        if alert.runModal() == .alertFirstButtonReturn {
            moveToApplications()
        }
    }
    
    private func moveToApplications() {
        let bundlePath = Bundle.main.bundlePath
        let appName = (bundlePath as NSString).lastPathComponent
        let destinationPath = "/Applications/\(appName)"
        
        do {
            // Remove existing app if present
            if FileManager.default.fileExists(atPath: destinationPath) {
                try FileManager.default.removeItem(atPath: destinationPath)
            }
            
            // Copy to Applications
            try FileManager.default.copyItem(atPath: bundlePath, toPath: destinationPath)
            
            // Launch from new location
            let url = URL(fileURLWithPath: destinationPath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                // Quit the current instance
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could not move application"
            errorAlert.informativeText = "Please manually drag Just Speak to It to your Applications folder. Error: \(error.localizedDescription)"
            errorAlert.runModal()
        }
    }
    
    private func checkForMountedDMG() {
        let fileManager = FileManager.default
        
        do {
            let volumes = try fileManager.contentsOfDirectory(atPath: "/Volumes")
            
            for volume in volumes {
                let volumePath = "/Volumes/\(volume)"
                let appPath = "\(volumePath)/JustSpeakToIt.app"
                
                // Check if this looks like our DMG
                if volume.contains("Just Speak") || fileManager.fileExists(atPath: appPath) {
                    showEjectDMGAlert(volumeName: volume)
                    break
                }
            }
        } catch {
            // Ignore errors reading volumes
        }
    }
    
    private func showEjectDMGAlert(volumeName: String) {
        let alert = NSAlert()
        alert.messageText = "Eject Installer?"
        alert.informativeText = "Just Speak to It has been installed. Would you like to eject the installer disk image and move it to Trash?"
        alert.addButton(withTitle: "Eject & Trash")
        alert.addButton(withTitle: "Just Eject")
        alert.addButton(withTitle: "Keep Mounted")
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Eject and trash
            ejectAndTrashDMG(volumeName: volumeName)
        } else if response == .alertSecondButtonReturn {
            // Just eject
            ejectDMG(volumeName: volumeName)
        }
    }
    
    private func ejectDMG(volumeName: String) {
        let volumePath = "/Volumes/\(volumeName)"
        NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath)
    }
    
    private func ejectAndTrashDMG(volumeName: String) {
        // First, find the DMG file path before ejecting
        let volumePath = "/Volumes/\(volumeName)"
        
        // Get disk info to find source DMG
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let images = plist["images"] as? [[String: Any]] {
                
                for image in images {
                    if let systemEntities = image["system-entities"] as? [[String: Any]] {
                        for entity in systemEntities {
                            if let mountPoint = entity["mount-point"] as? String,
                               mountPoint == volumePath,
                               let imagePath = image["image-path"] as? String {
                                
                                // Eject first
                                NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath)
                                
                                // Then trash the DMG
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    let dmgURL = URL(fileURLWithPath: imagePath)
                                    try? FileManager.default.trashItem(at: dmgURL, resultingItemURL: nil)
                                }
                                return
                            }
                        }
                    }
                }
            }
        } catch {
            // Fallback: just eject
            ejectDMG(volumeName: volumeName)
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
