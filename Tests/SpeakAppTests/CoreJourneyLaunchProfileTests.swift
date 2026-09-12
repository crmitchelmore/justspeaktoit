#if DEBUG
import Foundation
import XCTest
@testable import SpeakApp

@MainActor
final class CoreJourneyLaunchProfileTests: XCTestCase {
    func testSharedDirectory_requiresMatchingUUIDUnderSystemTemporaryRoot() {
        let identifier = UUID()
        let name = "com.justspeaktoit.tests.core-journey.\(identifier.uuidString)"
        let expected = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true).resolvingSymlinksInPath()
        XCTAssertEqual(
            CoreJourneyLaunchProfile.validatedSharedDirectory("/tmp/\(name)", identifier: identifier), expected
        )
        XCTAssertEqual(
            CoreJourneyLaunchProfile.validatedSharedDirectory(expected.path, identifier: identifier), expected
        )
        for path in ["/tmp", name, "/Users/Shared/\(name)", "/tmp/another-launch", "/tmp/\(name)/nested"] {
            XCTAssertNil(CoreJourneyLaunchProfile.validatedSharedDirectory(path, identifier: identifier), path)
        }
    }

    func testSharedDirectory_rejectsSymlinkOutsideTemporaryRoot() throws {
        let identifier = UUID()
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("com.justspeaktoit.tests.core-journey.\(identifier.uuidString)")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: URL(fileURLWithPath: "/Users"))
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(CoreJourneyLaunchProfile.validatedSharedDirectory(directory.path, identifier: identifier))
    }

    func testProfile_disablesCaptureAndExternalActionsWithTypedDefaults() {
        let profile = makeProfile()

        for key in [
            "audioPreWarmingEnabled", "connectionPreWarmingEnabled", "handsFreeDictationEnabled",
            "enableSendToMac", "enableAutomationServer", "analyticsEnabled"
        ] {
            XCTAssertEqual(profile.defaults.object(forKey: key) as? Bool, false, key)
        }
        XCTAssertFalse(profile.probesHotKey)
        XCTAssertFalse(profile.settings.audioPreWarmingEnabled)
        XCTAssertFalse(profile.settings.connectionPreWarmingEnabled)
        XCTAssertFalse(profile.settings.handsFreeDictationEnabled)
        XCTAssertFalse(profile.settings.enableSendToMac)
        XCTAssertFalse(profile.settings.enableAutomationServer)
        XCTAssertFalse(profile.settings.analyticsEnabled)

        let options = profile.bootstrapOptions()
        XCTAssertTrue(options.settingsOverride === profile.settings)
        XCTAssertEqual(options.keychainServiceOverride, profile.suiteName)
        XCTAssertFalse(options.sweepsStagedLeftovers)
        XCTAssertEqual(options.permissionsOverride?.status(for: .microphone), .denied)
        XCTAssertEqual(options.permissionsOverride?.status(for: .inputMonitoring), .denied)
    }

    func testProfile_isolatesSettingsAndFileStorageForEachLaunch() {
        let first = makeProfile()
        let second = makeProfile()
        first.settings.audioPreWarmingEnabled = true

        XCTAssertFalse(second.settings.audioPreWarmingEnabled)
        XCTAssertNotEqual(first.suiteName, second.suiteName)
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(
            first.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask),
            [first.directory]
        )
        XCTAssertEqual(
            first.settings.recordingsDirectory,
            first.directory.appendingPathComponent("Recordings", isDirectory: true)
        )
    }

    func testHotKeyProbe_usesSupportedCarbonChordWithoutGrantingCapturePermissions() {
        let profile = makeProfile(probesHotKey: true)

        XCTAssertTrue(profile.probesHotKey)
        XCTAssertTrue(profile.settings.selectedHotKey.isSupportedForGlobalMonitoring)
        XCTAssertFalse(profile.settings.selectedHotKey.isFnKey)
        XCTAssertEqual(profile.settings.selectedHotKey.displayString, "⌃⌥⇧K")
        XCTAssertEqual(profile.settings.holdThreshold, 20)
        XCTAssertEqual(profile.settings.doubleTapWindow, 0.1)
        let permissions = profile.bootstrapOptions().permissionsOverride
        XCTAssertEqual(permissions?.status(for: .microphone), .denied)
        XCTAssertEqual(permissions?.status(for: .accessibility), .denied)
        XCTAssertEqual(permissions?.status(for: .inputMonitoring), .denied)
    }

    func testBatchJourney_usesRealPermissionsAndExplicitClipboardSettings() {
        let profile = makeProfile(runsBatchJourney: true)
        XCTAssertTrue(profile.runsBatchJourney)
        XCTAssertEqual(profile.settings.transcriptionMode, .batchRemote)
        XCTAssertEqual(profile.settings.batchTranscriptionModel, CoreJourneyBatchFixture.model)
        XCTAssertFalse(profile.settings.postProcessingEnabled)
        XCTAssertEqual(profile.settings.textOutputMethod, .clipboardOnly)
        XCTAssertFalse(profile.settings.restoreClipboardAfterPaste)
        XCTAssertFalse(profile.settings.recordingSoundsEnabled)
        XCTAssertFalse(profile.settings.silenceDetectionEnabled)
        XCTAssertEqual(profile.settings.hotKeyActivationStyle, .doubleTapToggle)
        XCTAssertEqual(profile.settings.doubleTapWindow, 15)
        let permissions = profile.bootstrapOptions().permissionsOverride
        let actualPermissions = PermissionsManager()
        for permission in PermissionType.allCases {
            XCTAssertEqual(permissions?.status(for: permission), actualPermissions.status(for: permission))
        }
    }

    private func makeProfile(probesHotKey: Bool = false, runsBatchJourney: Bool = false) -> CoreJourneyLaunchProfile {
        let profile = CoreJourneyLaunchProfile(
            identifier: UUID(), probesHotKey: probesHotKey, runsBatchJourney: runsBatchJourney
        )
        let suiteName = profile.suiteName
        let directory = profile.directory
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return profile
    }
}
#endif
