#if DEBUG
import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class KeepAudioOnCancelTests: XCTestCase {
    func testCancelRecording_KeepsAndReturnsAudioOnlyWhenAsked() async throws {
        let profile = CoreJourneyLaunchProfile(identifier: UUID())
        let suiteName = profile.suiteName
        let directory = profile.directory
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = AudioFileManager(
            appSettings: profile.settings,
            permissionsManager: PermissionsManager(statusProvider: { _ in .denied }),
            audioDeviceManager: AudioInputDeviceManager(appSettings: profile.settings),
            captureSource: CoreJourneyRecordingSource()
        )

        let kept = try await manager.startRecording(owner: .dictation)
        let keptURL = await manager.cancelRecording(deleteFile: false, ifOwnedBy: .dictation)
        XCTAssertEqual(keptURL, kept.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path))

        let discarded = try await manager.startRecording(owner: .dictation)
        let discardedURL = await manager.cancelRecording(deleteFile: true, ifOwnedBy: .dictation)
        XCTAssertNil(discardedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.url.path))
    }

    func testKeptRecording_RemovesEmptyFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: url)
        XCTAssertNil(AudioFileManager.keptRecording(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(AudioFileManager.keptRecording(at: nil))
    }

    func testSetting_DefaultsToKeepAndPersistsUnderCanonicalKey() {
        let profile = CoreJourneyLaunchProfile(identifier: UUID())
        defer {
            profile.defaults.removePersistentDomain(forName: profile.suiteName)
            try? FileManager.default.removeItem(at: profile.directory)
        }
        XCTAssertTrue(profile.settings.keepAudioOnCancel)
        profile.settings.keepAudioOnCancel = false
        XCTAssertEqual(
            profile.defaults.object(forKey: ApplicationPreferenceKey.keepAudioOnCancel.rawValue) as? Bool, false
        )
    }
}
#endif
