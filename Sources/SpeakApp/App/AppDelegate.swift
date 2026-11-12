import AppKit
import AVFoundation
import SpeakCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var environment: AppEnvironment?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless Sparkle self-update (scripts/sparkle-update-smoke.sh). Nothing
        // else in the app runs in this mode: no dock icon, no windows, no audio
        // engine warm-up, no DMG-cleanup prompts. The process is either killed by
        // Sparkle as it installs, or exits with a verdict of its own.
        if SparkleSmokeSession.isActive {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            SparkleSmokeSession.begin()
            return
        }

        NSApp.setActivationPolicy(.regular)
        // Keep SwiftPM runs and packaged apps on the same multi-resolution artwork.
        NSApp.applicationIconImage = AppIconProvider.applicationIcon()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        #if DEBUG
        if CoreJourneyLaunchProfile.isRequested { return }
        #endif
        DispatchQueue.global(qos: .utility).async { _ = AVAudioEngine() } // Sentry JUSTSPEAKTOIT-A
        // Raw-audio multipart bodies abandoned by a crash or force quit (#706).
        DispatchQueue.global(qos: .utility).async {
            MultipartUploadStaging.shared.purgeStaleUploads()
        }
        DiskImageInstallCleanup.offerIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor in
            await environment.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        guard sender.representedObject is UUID else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            // Would need to navigate to specific history item
        }
    }
}
