#if DEBUG
import Foundation
import XCTest
@testable import SpeakApp

@MainActor
final class CoreJourneyLaunchProfileTests: XCTestCase {
    func testProfile_disablesCaptureAndExternalActionsWithTypedDefaults() {
        let profile = makeProfile()

        for key in [
            "audioPreWarmingEnabled", "connectionPreWarmingEnabled", "handsFreeDictationEnabled",
            "enableSendToMac", "enableAutomationServer", "analyticsEnabled"
        ] {
            XCTAssertEqual(profile.defaults.object(forKey: key) as? Bool, false, key)
        }
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

    private func makeProfile() -> CoreJourneyLaunchProfile {
        let profile = CoreJourneyLaunchProfile(identifier: UUID())
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
