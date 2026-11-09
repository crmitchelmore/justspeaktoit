import XCTest

@testable import SpeakApp

/// The capture start reuses the microphone status queried at hotkey key-down
/// instead of paying for another TCC query on the trigger path (issue #611).
final class PermissionsFreshnessTests: XCTestCase {
    @MainActor
    private final class Probe {
        var now: TimeInterval = 100
        var queries = 0
        var microphone: PermissionStatus = .granted
    }

    @MainActor
    private func makeManager(_ probe: Probe) -> PermissionsManager {
        let defaults = UserDefaults(suiteName: "com.speakapp.tests.\(UUID().uuidString)")!
        let manager = PermissionsManager(
            statusProvider: { type in
                MainActor.assumeIsolated {
                    if type == .microphone { probe.queries += 1 }
                    return type == .microphone ? probe.microphone : .granted
                }
            },
            grantHistory: defaults
        )
        manager.uptime = { MainActor.assumeIsolated { probe.now } }
        probe.queries = 0
        return manager
    }

    @MainActor
    func testFreshKeyDownAnswerIsReusedAtCaptureStart() {
        let probe = Probe()
        let manager = self.makeManager(probe)
        manager.refresh(.microphone)
        XCTAssertEqual(probe.queries, 1)

        probe.now += 0.4
        manager.refresh(.microphone, ifOlderThan: AudioFileManager.microphoneStatusMaxAge)

        XCTAssertEqual(probe.queries, 1, "a key-down answer from 400 ms ago is authoritative")
        XCTAssertEqual(manager.status(for: .microphone), .granted)
    }

    @MainActor
    func testStaleAnswerIsQueriedAgainAndARevocationIsSeen() {
        let probe = Probe()
        let manager = self.makeManager(probe)
        manager.refresh(.microphone)

        probe.now += AudioFileManager.microphoneStatusMaxAge + 0.1
        probe.microphone = .denied
        manager.refresh(.microphone, ifOlderThan: AudioFileManager.microphoneStatusMaxAge)

        XCTAssertEqual(probe.queries, 2)
        XCTAssertEqual(manager.status(for: .microphone), .denied)
    }

    @MainActor
    func testClockGoingBackwardsNeverTrustsTheCache() {
        let probe = Probe()
        let manager = self.makeManager(probe)
        manager.refresh(.microphone)

        probe.now -= 1
        manager.refresh(.microphone, ifOlderThan: AudioFileManager.microphoneStatusMaxAge)

        XCTAssertEqual(probe.queries, 2)
    }
}
