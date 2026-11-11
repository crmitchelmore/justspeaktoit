import XCTest

@testable import SpeakApp

/// The capture start reads main-actor state before the recorder's actor runs,
/// so `record()` never queues behind the HUD render on the main thread (#611).
final class CaptureStartPreflightTests: XCTestCase {
    @MainActor
    private final class Probe {
        var now: TimeInterval = 100
        var queries = 0
        var microphone: PermissionStatus = .granted
    }

    @MainActor
    private func makeAudioFileManager(_ probe: Probe) -> (AudioFileManager, AppSettings) {
        let defaults = UserDefaults(suiteName: "com.speakapp.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager(
            statusProvider: { type in
                MainActor.assumeIsolated {
                    if type == .microphone { probe.queries += 1 }
                    return type == .microphone ? probe.microphone : .granted
                }
            },
            grantHistory: defaults
        )
        permissions.uptime = { MainActor.assumeIsolated { probe.now } }
        permissions.refresh(.microphone)
        probe.queries = 0
        let manager = AudioFileManager(
            appSettings: settings,
            permissionsManager: permissions,
            audioDeviceManager: AudioInputDeviceManager(appSettings: settings)
        )
        return (manager, settings)
    }

    @MainActor
    func testPreflight_ReusesFreshKeyDownStatusAndCarriesStartState() async {
        let probe = Probe()
        let (manager, settings) = self.makeAudioFileManager(probe)
        probe.now += 0.4

        let preflight = await manager.makeStartPreflight()

        XCTAssertEqual(probe.queries, 0, "a fresh key-down answer needs no TCC query")
        XCTAssertTrue(preflight.microphoneGranted)
        XCTAssertNotNil(preflight.inputSession)
        XCTAssertEqual(preflight.recordingsDirectory, settings.recordingsDirectory)
    }

    @MainActor
    func testPreflight_StaleRevokedStatusIsQueriedAndOpensNoInputSession() async {
        let probe = Probe()
        let (manager, _) = self.makeAudioFileManager(probe)
        probe.now += AudioFileManager.microphoneStatusMaxAge + 0.1
        probe.microphone = .denied

        let preflight = await manager.makeStartPreflight()

        XCTAssertEqual(probe.queries, 1)
        XCTAssertFalse(preflight.microphoneGranted)
        XCTAssertNil(preflight.inputSession)
    }

    func testStartingHUD_ShownUpFrontOnlyToCoverAnUnprimedInputBuild() {
        XCTAssertTrue(StartingHUDTiming.presentsBeforeInputBuild(buildsInputNode: true, hasPrimedInput: false))
        XCTAssertFalse(StartingHUDTiming.presentsBeforeInputBuild(buildsInputNode: true, hasPrimedInput: true))
        XCTAssertFalse(StartingHUDTiming.presentsBeforeInputBuild(buildsInputNode: false, hasPrimedInput: false))
    }
}
