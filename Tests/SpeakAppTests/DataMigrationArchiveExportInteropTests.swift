import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationArchiveExportInteropTests: XCTestCase {
    func testNativeZIP64Export_IsAcceptedByMacZIPFoundationWithRealCryptoKitDigest() throws {
        let digests = try XCTUnwrap(LocalModelDigestProvider.platformDefault)
        let source = try MigrationArchive.read(MigrationArchiveFixtures.url("long-unicode"))
        removeStaging(source)
        let file = try DesktopMigrationArchive.export(source, digests: digests)
        addTeardownBlock { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try MigrationArchive.read(file)
        removeStaging(result)
        XCTAssertEqual(result.records, source.records)
        XCTAssertEqual(result.manifest.categories, source.manifest.categories)
        XCTAssertEqual(result.manifest.scopes, source.manifest.scopes)
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(Set(result.files.keys), Set(source.files.keys))
        for (path, audio) in result.files {
            XCTAssertEqual(try Data(contentsOf: audio), try Data(contentsOf: XCTUnwrap(source.files[path])))
        }
    }

    func testMacZIPFoundationExport_IsAcceptedByNativeReaderWithoutChangingCanonicalRecords() throws {
        let digests = try XCTUnwrap(LocalModelDigestProvider.platformDefault)
        let source = try MigrationArchive.read(MigrationArchiveFixtures.url("zip64"))
        removeStaging(source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mac-export.zip")
        try MigrationArchive.write(source, to: file)
        let result = try DesktopMigrationArchive.read(file, digests: digests)
        removeStaging(result)
        XCTAssertEqual(result.records, source.records)
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files["recordings/test.wav"])),
                       MigrationArchiveFixtures.audio)
    }

    private func removeStaging(_ snapshot: DataMigrationSnapshot) {
        guard let directory = snapshot.directory else {
            XCTFail("An archive read did not return its owned staging directory.")
            return
        }
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    }
}
