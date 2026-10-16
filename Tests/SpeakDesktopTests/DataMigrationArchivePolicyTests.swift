import Foundation
import SpeakCore
import XCTest

final class DataMigrationArchivePolicyTests: XCTestCase {
    private typealias Policy = DataMigrationArchivePolicy

    func testArchiveLimits_AcceptExactBoundsAndRejectOneByteOver() throws {
        let exact: [Policy.Entry] = [
            .init(path: "one", uncompressedBytes: 20_000_000_000),
            .init(path: "two", uncompressedBytes: 20_000_000_000),
            .init(path: "three", uncompressedBytes: 10_000_000_000)
        ]
        XCTAssertEqual(try Policy.preflight(exact), 50_000_000_000)
        XCTAssertThrowsError(try Policy.preflight([.init(path: "one", uncompressedBytes: 20_000_000_001)]))
        XCTAssertThrowsError(try Policy.preflight(exact + [.init(path: "four", uncompressedBytes: 1)]))
        XCTAssertThrowsError(try Policy.preflight([.init(path: "one", uncompressedBytes: UInt64.max)]))
    }

    func testEntryLimits_RejectDuplicatesAndStopAfterFirstExcessEntry() throws {
        XCTAssertThrowsError(try Policy.preflight([
            .init(path: "manifest.json", uncompressedBytes: 0),
            .init(path: "manifest.json", uncompressedBytes: 0)
        ]))
        let exact = (0..<100_000).lazy.map { Policy.Entry(path: String($0), uncompressedBytes: 0) }
        XCTAssertEqual(try Policy.preflight(exact), 0)
        var consumed = 0
        let oversized = (0..<100_002).lazy.map {
            consumed += 1
            return Policy.Entry(path: String($0), uncompressedBytes: 0)
        }
        XCTAssertThrowsError(try Policy.preflight(oversized))
        XCTAssertEqual(consumed, 100_001)
    }

    func testStagingCapacity_PreservesReserveAndRejectsOverflow() {
        XCTAssertNoThrow(try Policy.requireStagingCapacity(archiveBytes: 50_000_000_000, availableBytes: nil))
        XCTAssertNoThrow(try Policy.requireStagingCapacity(
            archiveBytes: 50_000_000_000, availableBytes: 50_064_000_000
        ))
        XCTAssertThrowsError(try Policy.requireStagingCapacity(
            archiveBytes: 50_000_000_000, availableBytes: 50_063_999_999
        ))
        XCTAssertThrowsError(try Policy.requireStagingCapacity(archiveBytes: 0, availableBytes: 63_999_999))
        XCTAssertThrowsError(try Policy.requireStagingCapacity(archiveBytes: UInt64.max, availableBytes: UInt64.max))
    }

    func testManifest_RejectsUnsupportedFormatVersionAndDuplicateCategories() {
        let valid = DataMigrationManifest(categories: [.settings, .history], scopes: [:])
        XCTAssertNoThrow(try Policy.validateManifest(valid))
        var invalid = valid
        invalid.format = "another-product"
        XCTAssertThrowsError(try Policy.validateManifest(invalid))
        invalid = valid
        invalid.version += 1
        XCTAssertThrowsError(try Policy.validateManifest(invalid))
        invalid = valid
        invalid.categories = [.settings, .settings]
        XCTAssertThrowsError(try Policy.validateManifest(invalid))
    }

    func testAudioPaths_PreserveExactVersionOneAcceptance() {
        for ext in ["wav", "m4a", "mp3", "flac", "ogg", "aiff", "aif", "aac", "caf", "audio"] {
            XCTAssertTrue(Policy.safeAudioPath("recordings/fixture.\(ext)"))
            XCTAssertTrue(Policy.safeAudioPath("recordings/fixture.\(ext.uppercased())"))
        }
        for path in [
            "../a.wav", "/recordings/a.wav", "recordings/../a.wav", "recordings/..\\a.wav",
            "recordings/a/b.wav", "recordings/run.command", "recordings/a.wav\0",
            "recordings/", "Recordings/a.wav", "recordings/a..b.wav",
            "recordings/a.webm", "recordings/a.m4b", "recordings/a.opus"
        ] {
            XCTAssertFalse(Policy.safeAudioPath(path), path)
        }
    }
}
