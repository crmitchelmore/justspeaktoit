#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class KeepAudioOnCancelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSetting_DefaultsToKeepAndPersistsUnderCanonicalKey() throws {
        let suiteName = "KeepAudioOnCancelTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(AppSettings.storedKeepAudioOnCancel(in: suite))

        let settings = AppSettings(defaults: suite, loadsSecureStorage: false)
        XCTAssertTrue(settings.keepAudioOnCancel)
        settings.keepAudioOnCancel = false
        XCTAssertEqual(suite.object(forKey: ApplicationPreferenceKey.keepAudioOnCancel.rawValue) as? Bool, false)
        XCTAssertFalse(AppSettings.storedKeepAudioOnCancel(in: suite))
    }

    func testCancelledRecording_KeptOnlyWhenEnabledAndHoldingAudio() throws {
        let url = directory.appendingPathComponent("Recording.m4a")
        try Data(repeating: 1, count: 64).write(to: url)
        let now = Date()
        let started = now.addingTimeInterval(-2)

        XCTAssertTrue(AudioRecordingPersistence.shouldKeepCancelledRecording(
            at: url, startedAt: started, keepAudio: true, now: now))
        XCTAssertFalse(AudioRecordingPersistence.shouldKeepCancelledRecording(
            at: url, startedAt: started, keepAudio: false, now: now))
        XCTAssertFalse(AudioRecordingPersistence.shouldKeepCancelledRecording(
            at: url, startedAt: now.addingTimeInterval(-0.1), keepAudio: true, now: now))
        XCTAssertFalse(AudioRecordingPersistence.shouldKeepCancelledRecording(
            at: url, startedAt: nil, keepAudio: true, now: now))

        let empty = directory.appendingPathComponent("Empty.m4a")
        try Data().write(to: empty)
        XCTAssertFalse(AudioRecordingPersistence.shouldKeepCancelledRecording(
            at: empty, startedAt: started, keepAudio: true, now: now))
    }
}
#endif
