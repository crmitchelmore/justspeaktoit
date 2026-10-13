import CLinuxSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakLinuxPlatform
import XCTest

final class LinuxRecordingFeedbackTests: XCTestCase {
    func testAllEightBundledAACAssets_DecodeWithProductionBounds() async throws {
        for profile in RecordingFeedbackProfile.allCases {
            let output = try await LinuxRecordingFeedbackLoader.checkAssets(profile: profile)
            XCTAssertEqual(output, 2)
        }
    }

    func testMissingEmptyAndSymbolicLinkAssets_AreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        let link = directory.appendingPathComponent("linked.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        for path in [directory, empty, link, directory.appendingPathComponent("missing.m4a")] {
            var error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(jsti_recording_feedback_check_asset(path.path, &error, error.count), -1)
            XCTAssertFalse(String(cString: error).isEmpty)
        }
    }

    func testCancelledPreparation_DoesNotOpenAChannel() {
        let handle = jsti_recording_feedback_create(nil, nil)
        defer { jsti_recording_feedback_destroy(handle) }
        jsti_recording_feedback_cancel_preparation(handle)
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(jsti_recording_feedback_prepare(handle, "unused.m4a", "unused.m4a", &error, error.count), 1)
    }

    func testDecodedPCMOverTenSeconds_IsRefusedEvenWhenEncodedFileIsSmall() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("long.wav")
        let file = try PCMRecordingFile(url: path, sampleRate: 8_000)
        try file.append(Data(repeating: 1, count: 8_000 * 11 * 2))
        _ = try file.finish()
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(jsti_recording_feedback_check_asset(path.path, &error, error.count), -1)
        XCTAssertTrue(String(cString: error).contains("ten seconds"))
    }
}
