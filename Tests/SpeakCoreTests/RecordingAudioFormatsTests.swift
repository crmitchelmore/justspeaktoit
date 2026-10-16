import XCTest
@testable import SpeakCore

final class RecordingAudioFormatsTests: XCTestCase {
    func testArchivePolicy_PreservesMacProjectionAndIncludesEveryImportFormat() {
        XCTAssertEqual(RecordingAudioFormats.macArchiveExtensions, ["aac", "caf", "m4a", "m4b", "mp3", "wav"])
        XCTAssertTrue(RecordingAudioFormats.importExtensions.isSubset(of: RecordingAudioFormats.archiveExtensions))
        XCTAssertTrue(RecordingAudioFormats.archiveExtensions.contains("m4b"))
        XCTAssertFalse(RecordingAudioFormats.importExtensions.contains("m4b"))
        XCTAssertFalse(RecordingAudioFormats.archiveExtensions.contains("json"))
        XCTAssertFalse(RecordingAudioFormats.archiveExtensions.contains("txt"))
        XCTAssertEqual(RecordingAudioFormats.archiveExtensions.count, RecordingAudioFormats.importExtensions.count + 1)
    }
}
