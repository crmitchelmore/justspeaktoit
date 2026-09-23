import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// End-to-end checks of the native adapters against real services, run by
/// scripts/linux-integration-checks.sh inside a disposable session: a private
/// bus, an unlocked keyring, PipeWire with a test tone source, an X server with
/// a window manager and a fake XDG portal. Each check fails loudly when its
/// service is missing; nothing is skipped.
enum LinuxIntegrationChecks {
    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw DesktopHostError(message: "Integration check failed: \(message())") }
    }

    static func environment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw DesktopHostError(message: "Integration check needs \(name).")
        }
        return value
    }

    /// Keyring round trip under a throwaway identifier.
    static func keyring() throws {
        let name = "jsti-integration-\(UUID().uuidString)"
        try LinuxCredentialStore.save("  secret-ключ-🔑  ", name: name)
        try require(try LinuxCredentialStore.read(name: name) == "secret-ключ-🔑", "the saved key did not round-trip")
        try LinuxCredentialStore.save("", name: name)
        try require(try LinuxCredentialStore.read(name: name).isEmpty, "an empty save did not remove the key")
        print("Keyring: saved, read and removed a Unicode key.")
    }

    /// Records from the test source and checks framing and signal.
    static func capture() throws {
        let source = try environment("JSTI_TEST_SOURCE")
        let devices = try LinuxAudioCapture.devices()
        try require(!devices.contains { $0.id.hasSuffix(".monitor") }, "speaker monitors were listed as microphones")
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var frames: [Int] = []
            var peak: Int16 = 0
            var failure: String?
        }
        let collected = Collected()
        let capture = try LinuxAudioCapture(
            device: source, sampleRate: 16_000, frameMilliseconds: 100,
            audio: { samples in
                let peak = samples.map { $0 == Int16.min ? Int16.max : abs($0) }.max() ?? 0
                collected.lock.withLock {
                    collected.frames.append(samples.count)
                    collected.peak = max(collected.peak, peak)
                }
            },
            failure: { message in collected.lock.withLock { collected.failure = message } }
        )
        try capture.start()
        Thread.sleep(forTimeInterval: 1.5)
        try capture.stop()
        capture.destroy()
        let (frames, peak, failure) = collected.lock.withLock { (collected.frames, collected.peak, collected.failure) }
        try require(failure == nil, "capture reported \(failure ?? "")")
        let total = frames.reduce(0, +)
        try require(total >= 16_000, "only \(total) samples arrived in 1.5 s")
        try require(frames.dropLast().allSatisfy { $0 == 1_600 }, "frames were not exactly 100 ms: \(frames)")
        try require(peak > 1_000, "the captured audio was silent (peak \(peak))")
        print("Capture: \(total) samples in \(frames.count) frames from \(source), peak \(peak).")
    }

    /// X11 paste into a real window, with focus re-verification and clipboard
    /// restore. Runs inside the GTK loop, which serves the clipboard.
    static func x11() throws {
        let raw = try environment("JSTI_TEST_TARGET_WINDOW")
        guard let expected = UInt64(raw) else { throw DesktopHostError(message: "Bad JSTI_TEST_TARGET_WINDOW \(raw)") }
        // The script raises the target once this app's window has appeared.
        var target: LinuxInsertionTarget?
        for _ in 0..<500 {
            if let captured = LinuxX11.captureTarget(), captured.kind == .x11Window(expected) {
                target = captured
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let target else { throw DesktopHostError(message: "Integration check: the target never became active.") }
        try LinuxClipboard.write("previous clipboard")
        let session = LinuxDesktopSession()
        guard let plan = LinuxOutputPlan.make(
            options: .init(), target: target, session: session, portalAvailable: false
        ) else { throw DesktopHostError(message: "Integration check: no plan for an X11 target.") }
        let status = LinuxOutputJob(plan: plan, native: LinuxOutputNativeAdapter()).perform("X11 dictation ✓")
        try require(status.contains("restored"), "X11 paste reported: \(status)")
        try require(try LinuxClipboard.read() == "previous clipboard", "the clipboard was not restored")
        let moved = LinuxOutputJob(
            plan: .x11Paste(window: expected &+ 99_991, shift: false, restoreClipboard: true),
            native: LinuxOutputNativeAdapter()
        ).perform("must not paste")
        try require(moved.contains("focused window changed"), "a stale target was pasted into: \(moved)")
        print("X11: pasted into the captured window, restored the clipboard and refused a stale target.")
    }

    /// The X11 Ctrl+Alt+Space grab: the script presses the key with XTest once
    /// the grab is in place (signalled by creating JSTI_TEST_READY_FILE).
    static func x11Hotkey() throws {
        let readyFile = try environment("JSTI_TEST_READY_FILE")
        final class Presses: @unchecked Sendable {
            let lock = NSLock()
            var events: [Int32] = []
        }
        let presses = Presses()
        try withExtendedLifetime(presses) {
            try LinuxNative.call {
                jsti_x11_hotkey_start(
                    LinuxShortcuts.x11Keysym, LinuxShortcuts.x11Modifiers, { pressed, context in
                        let presses = Unmanaged<Presses>.fromOpaque(context!).takeUnretainedValue()
                        presses.lock.withLock { presses.events.append(pressed) }
                    }, Unmanaged.passUnretained(presses).toOpaque(), $0, $1
                )
            }
            FileManager.default.createFile(atPath: readyFile, contents: Data())
            for _ in 0..<1_000 where presses.lock.withLock({ presses.events.count }) < 2 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            jsti_x11_hotkey_stop()
        }
        let events = presses.lock.withLock { presses.events }
        try require(events == [1, 0], "the grab reported \(events)")
        print("X11 shortcut: Ctrl+Alt+Space grab reported one press and one release.")
    }

    /// GlobalShortcuts and RemoteDesktop/Clipboard against the fake portal.
    static func portal() throws {
        try require(LinuxPortal.version(of: LinuxPortal.globalShortcuts) != nil, "GlobalShortcuts is not offered")
        try require(LinuxPortal.version(of: LinuxPortal.remoteDesktop) != nil, "RemoteDesktop is not offered")
        final class Presses: @unchecked Sendable {
            let lock = NSLock()
            var events: [Int32] = []
        }
        let presses = Presses()
        var trigger = [CChar](repeating: 0, count: 128)
        try withExtendedLifetime(presses) {
            try LinuxNative.call {
                jsti_shortcuts_start(
                    LinuxShortcuts.portalShortcutID, "Start or stop dictation", "CTRL+ALT+space", { pressed, context in
                        let presses = Unmanaged<Presses>.fromOpaque(context!).takeUnretainedValue()
                        presses.lock.withLock { presses.events.append(pressed) }
                    }, Unmanaged.passUnretained(presses).toOpaque(), &trigger, trigger.count, $0, $1
                )
            }
            try require(String(cString: trigger) == "Ctrl+Alt+Space", "the bound trigger was \(String(cString: trigger))")
            // The fake portal presses and releases the shortcut after binding.
            for _ in 0..<200 where presses.lock.withLock({ presses.events.count }) < 2 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            jsti_shortcuts_stop()
        }
        try require(presses.lock.withLock { presses.events } == [1, 0], "shortcut events were \(presses.events)")
        print("GlobalShortcuts: bound Ctrl+Alt+Space and received Activated then Deactivated.")

        // First run: no token, consent, a new token saved to the keyring.
        try? LinuxCredentialStore.save("", name: LinuxOutputNativeAdapter.restoreTokenCredential)
        let job = LinuxOutputJob(plan: .portalPaste(shift: false), native: LinuxOutputNativeAdapter())
        let status = job.perform("Portal dictation ✓")
        try require(status.hasPrefix("Transcript pasted"), "portal paste reported: \(status)")
        let token = try LinuxCredentialStore.read(name: LinuxOutputNativeAdapter.restoreTokenCredential)
        try require(token == "fake-restore-token-1", "the restore token was not saved (\(token))")
        // The target asks for the selection after the keystroke; keep the
        // session open long enough to serve it, as a running app does.
        Thread.sleep(forTimeInterval: 0.3)
        LinuxPortal.stopRemoteDesktop()
        // Second run resumes with the saved token.
        let shifted = LinuxOutputJob(plan: .portalPaste(shift: true), native: LinuxOutputNativeAdapter())
        _ = shifted.perform("Second")
        Thread.sleep(forTimeInterval: 0.3)
        LinuxPortal.stopRemoteDesktop()
        print("RemoteDesktop: pasted through the shared clipboard and resumed with the saved restore token.")
    }
}
