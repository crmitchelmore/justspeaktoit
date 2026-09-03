import AppKit
import Combine
import SpeakHotKeys
import XCTest

@testable import SpeakApp

/// Covers the lifetime of the system-wide key-down monitor.
///
/// `installMonitoring` used to install `NSEvent.addGlobalMonitorForEvents` once and keep it
/// for the whole run of the app, routing every key press in every app through
/// `handleKeyboardShortcuts`. ⌘R in Safari reached `retryPostProcessing()` and Escape
/// anywhere reached `cancelRecordingWithEscape()`; only the handlers' own early returns kept
/// that harmless, which is a weaker contract than not listening at all.
@MainActor
final class HotKeyManagerGlobalMonitorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var monitoring: MonitorSpy!
    private var recordingState: CurrentValueSubject<Bool, Never>!
    private var manager: HotKeyManager!

    override func setUp() {
        super.setUp()
        suiteName = "com.justspeaktoit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        monitoring = MonitorSpy()
        recordingState = CurrentValueSubject(false)
        let settings = AppSettings(defaults: defaults)
        // The hotkey backend is a separate mechanism and is deliberately kept out of these
        // tests: an unsupported binding makes `HotKeyEngine.start` refuse, so no real event
        // tap or Carbon registration happens while the NSEvent monitors are under test.
        settings.selectedHotKey = .custom(keyCode: 0, modifiers: [])
        manager = HotKeyManager(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
            appSettings: settings,
            eventMonitoring: monitoring
        )
    }

    override func tearDown() {
        manager.stopMonitoring()
        manager = nil
        recordingState = nil
        monitoring = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Lifetime

    func testWhileIdle_noSystemWideMonitorIsInstalled() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()

        XCTAssertEqual(
            monitoring.liveGlobalMonitors, 0,
            "an idle app has nothing to cancel, so it should not be reading other apps' keys"
        )
        XCTAssertEqual(
            monitoring.liveLocalMonitors, 1,
            "app-context shortcuts still need the local monitor"
        )
    }

    func testWhileRecording_exactlyOneSystemWideMonitorIsInstalled() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()

        recordingState.send(true)

        XCTAssertEqual(monitoring.liveGlobalMonitors, 1)
        XCTAssertEqual(monitoring.globalInstalls, 1)
        XCTAssertEqual(monitoring.globalMasks, [[.keyDown]])
    }

    func testWhenRecordingEnds_theSystemWideMonitorIsRemoved() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()

        recordingState.send(true)
        recordingState.send(false)

        XCTAssertEqual(monitoring.liveGlobalMonitors, 0)
    }

    /// A second monitor would deliver every key press twice and leak, because only one
    /// token is remembered.
    func testRepeatedRecordingTransitions_doNotStackMonitors() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()

        recordingState.send(true)
        recordingState.send(true)
        manager.setGlobalEscapeNeeded(true, for: .recording)

        XCTAssertEqual(monitoring.globalInstalls, 1)
        XCTAssertEqual(monitoring.liveGlobalMonitors, 1)
    }

    func testStoppingMonitoringMidRecording_removesTheSystemWideMonitor() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()
        recordingState.send(true)

        manager.stopMonitoring()

        XCTAssertEqual(monitoring.liveGlobalMonitors, 0)
        XCTAssertEqual(monitoring.liveLocalMonitors, 0)
    }

    /// Pausing for hotkey re-recording tears everything down; resuming has to put the
    /// listener back, because the recording it was cancelling is still running.
    func testRestartingMonitoringWhileStillRecording_reinstallsTheSystemWideMonitor() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()
        recordingState.send(true)

        manager.stopMonitoring()
        manager.startMonitoring()

        XCTAssertEqual(monitoring.liveGlobalMonitors, 1)
    }

    /// A voice edit runs against another app's window too, so its Escape needs the same
    /// reach — and a dictation recording ending must not pull the listener out from under it.
    func testVoiceEditReason_outlivesTheRecordingReason() {
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()

        recordingState.send(true)
        manager.setGlobalEscapeNeeded(true, for: .voiceEdit)
        recordingState.send(false)

        XCTAssertEqual(monitoring.liveGlobalMonitors, 1)

        manager.setGlobalEscapeNeeded(false, for: .voiceEdit)

        XCTAssertEqual(monitoring.liveGlobalMonitors, 0)
    }

    // MARK: - What the system-wide monitor may fire

    func testSystemWideMonitor_doesNotFireCommandR() {
        var retries = 0
        manager.register(shortcut: .commandR) { retries += 1 }
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()
        recordingState.send(true)

        monitoring.sendGlobal(Self.keyDown(keyCode: 15, modifiers: [.command]))

        XCTAssertEqual(
            retries, 0,
            "⌘R is Safari's reload and Xcode's run; retrying post-processing is app context"
        )
    }

    func testSystemWideMonitor_firesEscape() {
        var cancels = 0
        manager.register(shortcut: .escape) { cancels += 1 }
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()
        recordingState.send(true)

        monitoring.sendGlobal(Self.keyDown(keyCode: 53, modifiers: []))

        XCTAssertEqual(cancels, 1, "Escape must cancel a live recording from whichever app it arrives in")
    }

    /// Escape deliberately ignores modifiers, because a hold on a chord hotkey keeps those
    /// modifiers physically down for the whole recording.
    func testSystemWideMonitor_firesEscapeWithTheHotKeyChordStillHeld() {
        var cancels = 0
        manager.register(shortcut: .escape) { cancels += 1 }
        manager.trackRecordingState(recordingState)
        manager.startMonitoring()
        recordingState.send(true)

        monitoring.sendGlobal(Self.keyDown(keyCode: 53, modifiers: [.option]))

        XCTAssertEqual(cancels, 1)
    }

    func testOnlyEscapeIsDeclaredAsGloballyDelivered() {
        XCTAssertEqual(KeyboardShortcut.allCases.filter(\.deliveredGlobally), [.escape])
    }

    // MARK: - Helpers

    private static func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        else {
            preconditionFailure("NSEvent.keyEvent should always build a synthetic key-down")
        }
        return event
    }
}

/// Records monitor installs and removals instead of touching the process-wide event stream.
private final class MonitorSpy: KeyEventMonitoring {
    /// Identifies which monitor a `removeMonitor` call is retiring. `NSEvent` returns an
    /// opaque token, so the spy hands back one it can recognise.
    private final class Token {
        let isGlobal: Bool

        init(isGlobal: Bool) {
            self.isGlobal = isGlobal
        }
    }

    /// How many system-wide monitors have ever been installed, so a stacked install is
    /// visible even when the removals happen to balance.
    private(set) var globalInstalls = 0
    private(set) var liveGlobalMonitors = 0
    private(set) var liveLocalMonitors = 0
    private(set) var globalMasks: [NSEvent.EventTypeMask] = []

    private var globalHandlers: [ObjectIdentifier: (NSEvent) -> Void] = [:]

    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        let token = Token(isGlobal: true)
        globalInstalls += 1
        liveGlobalMonitors += 1
        globalMasks.append(mask)
        globalHandlers[ObjectIdentifier(token)] = handler
        return token
    }

    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        liveLocalMonitors += 1
        return Token(isGlobal: false)
    }

    func removeMonitor(_ monitor: Any) {
        guard let token = monitor as? Token else { return }
        if token.isGlobal {
            liveGlobalMonitors -= 1
            globalHandlers[ObjectIdentifier(token)] = nil
        } else {
            liveLocalMonitors -= 1
        }
    }

    /// Delivers an event the way a real system-wide monitor would.
    func sendGlobal(_ event: NSEvent) {
        for handler in globalHandlers.values {
            handler(event)
        }
    }
}
