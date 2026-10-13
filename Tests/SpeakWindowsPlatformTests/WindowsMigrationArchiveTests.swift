import Foundation
import SpeakDesktop
import SpeakTestSupport
import SpeakWindowsPlatform
import XCTest

final class WindowsMigrationArchiveTests: XCTestCase {
    func testArchiveAudio_UsesNativeCNGVerificationAndGeneratedStaging() throws {
        #if os(Windows)
        let result = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("zip64"), digests: WindowsSHA256Hasher.provider
        )
        let directory = try XCTUnwrap(result.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(result.files["recordings/test.wav"])
        XCTAssertEqual(try Data(contentsOf: file), MigrationArchiveFixtures.audio)
        XCTAssertTrue(result.notices.isEmpty)
        #else
        throw XCTSkip("Requires the native Windows CNG adapter.")
        #endif
    }
}
