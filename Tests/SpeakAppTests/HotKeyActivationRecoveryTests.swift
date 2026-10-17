import AppKit
import Combine
import SpeakHotKeys
import XCTest

@testable import SpeakApp

@MainActor
final class HotKeyActivationRecoveryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var manager: HotKeyManager!
    private var monitoring: RecoveryMonitorSpy!
    private var recording: CurrentValueSubject<Bool, Never>!

    override func setUp() {
        super.setUp()
        suiteName = "com.justspeaktoit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.selectedHotKey = .custom(keyCode: 0, modifiers: [])
        settings.cancelRecordingOnEscape = false
        monitoring = RecoveryMonitorSpy()
        recording = CurrentValueSubject(false)
        manager = HotKeyManager(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
            appSettings: settings,
            eventMonitoring: monitoring
        )
        manager.trackRecordingState(recording)
        manager.startMonitoring()
    }

    override func tearDown() {
        manager.stopMonitoring()
        manager = nil
        recording = nil
        monitoring = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDeferredActivation_rearmsWhenRecordingEndsEvenWithEscapeDisabled() async throws {
        recording.send(true)
        try await deferActivation()

        recording.send(false)
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(monitoring.localInstalls, 2)
    }

    func testDeferredActivation_waitsForHeldTriggerAfterRecordingEnds() async throws {
        recording.send(true)
        manager.engine.updateConfiguration(HotKeyConfiguration(holdThreshold: 0.01, doubleTapWindow: 0.2))
        manager.engine.gestureDetector.keyDown()
        try await Task.sleep(for: .milliseconds(50))
        try await deferActivation()

        recording.send(false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitoring.localInstalls, 1)
        XCTAssertTrue(manager.engine.gestureDetector.isHoldInProgress)

        manager.engine.gestureDetector.keyUp()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitoring.localInstalls, 2)
    }

    func testDeferredActivation_waitsForVoiceEditAfterRecordingEnds() async throws {
        recording.send(true)
        manager.setGlobalEscapeNeeded(true, for: .voiceEdit)
        try await deferActivation()

        recording.send(false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitoring.localInstalls, 1)

        manager.setGlobalEscapeNeeded(false, for: .voiceEdit)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitoring.localInstalls, 2)
    }

    func testStoppingMonitoring_retiresDeferredActivation() async throws {
        recording.send(true)
        try await deferActivation()

        manager.stopMonitoring()
        manager.startMonitoring()
        recording.send(false)
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(monitoring.localInstalls, 2, "only the explicit restart should install a monitor")
    }

    func testDeferredActivation_rechecksAReplacementRecordingBeforeRearming() async throws {
        recording.send(true)
        try await deferActivation()
        recording.send(false)
        recording.send(true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitoring.localInstalls, 1)

        recording.send(false)
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(monitoring.localInstalls, 2)
    }

    private func deferActivation() async throws {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(monitoring.localInstalls, 1, "activation must not interrupt an active capture")
    }
}

private final class RecoveryMonitorSpy: KeyEventMonitoring {
    private(set) var localInstalls = 0

    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        NSObject()
    }

    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        localInstalls += 1
        return NSObject()
    }

    func removeMonitor(_ monitor: Any) {}
}
