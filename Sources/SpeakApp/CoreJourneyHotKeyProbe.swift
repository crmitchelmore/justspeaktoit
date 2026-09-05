#if DEBUG
import AppKit
import ApplicationServices
import Combine
import Foundation
import SpeakHotKeys

/// Observes the production Carbon/gesture path. It cannot start a recording or
/// inject events. MainManager's capture handlers remain disabled in this profile.
@MainActor
final class CoreJourneyHotKeyProbe {
    private struct Event: Encodable {
        let stage: String
        let source: String
        let frontmostBundleID: String?
    }

    private struct Snapshot: Encodable {
        let processID: Int32
        let registered: Bool
        let accessibilityTrusted: Bool
        let events: [Event]
    }

    private let manager: HotKeyManager
    private let diagnosticsURL: URL
    private var events: [Event] = []
    private var tokens: [HotKeyListenerToken] = []
    private var keyState: AnyCancellable?

    init(manager: HotKeyManager, directory: URL) {
        self.manager = manager
        diagnosticsURL = directory.appendingPathComponent("hotkey-probe.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Cannot create hotkey probe diagnostics: \(error.localizedDescription)")
        }
        keyState = manager.engine.$isKeyDown.removeDuplicates().dropFirst().sink { [weak self] isDown in
            MainActor.assumeIsolated {
                self?.record(stage: isDown ? "keyDown" : "keyUp", source: "engine")
            }
        }
        for gesture in HotKeyGesture.allCases {
            tokens.append(manager.engine.register(gesture: gesture) { [weak self] event in
                self?.record(stage: event.gesture.rawValue, source: event.source)
            })
        }
        // RegisterEventHotKey does not require Input Monitoring. Do not request
        // Fn/event-tap permissions or claim that any OS permission was granted.
        manager.startMonitoring(requestPermission: false)
        persist()
    }

    private func record(stage: String, source: String) {
        events.append(Event(
            stage: stage,
            source: source,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ))
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            processID: ProcessInfo.processInfo.processIdentifier,
            registered: manager.engine.isMonitoring,
            accessibilityTrusted: AXIsProcessTrusted(),
            events: events
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: diagnosticsURL, options: .atomic)
        } catch {
            preconditionFailure("Cannot write hotkey probe diagnostics: \(error.localizedDescription)")
        }
    }
}
#endif
