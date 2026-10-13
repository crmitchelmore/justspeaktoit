import Foundation
import SpeakDesktop
import SpeakLinuxPlatform
import SpeakTestSupport
import XCTest

final class LinuxMigrationArchiveTests: XCTestCase {
    func testArchiveAudio_UsesNativeGLibVerificationAndGeneratedStaging() throws {
        let result = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("zip64"), digests: LinuxSHA256Hasher.provider
        )
        let directory = try XCTUnwrap(result.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(result.files["recordings/test.wav"])
        XCTAssertEqual(try Data(contentsOf: file), MigrationArchiveFixtures.audio)
        XCTAssertTrue(result.notices.isEmpty)
    }
}
