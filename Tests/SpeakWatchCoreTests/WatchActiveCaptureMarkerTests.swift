import Foundation
import SpeakWatchCore
import XCTest

/// A damaged active-capture marker must stay distinguishable from no marker,
/// and must never be deleted or overwritten.
final class WatchActiveCaptureMarkerTests: XCTestCase {
    private func makeMarkerURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("active-capture.json")
    }

    func testMissingMarker_isAbsent() throws {
        let registry = WatchActiveCaptureRegistry(fileURL: try makeMarkerURL())

        XCTAssertEqual(registry.loadMarker(), .absent)
        XCTAssertNil(registry.load())
    }

    func testReadableMarker_isPresent() throws {
        let registry = WatchActiveCaptureRegistry(fileURL: try makeMarkerURL())
        let capture = WatchActiveCapture(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.persist(capture)

        XCTAssertEqual(registry.loadMarker(), .present(capture))
    }

    func testUndecodableMarker_isCorruptNotAbsent_andIsNeverClearedOrOverwritten() throws {
        let markerURL = try makeMarkerURL()
        let damaged = Data("{\"id\": \"not-a-uuid\"".utf8)
        try damaged.write(to: markerURL)
        let registry = WatchActiveCaptureRegistry(fileURL: markerURL)

        guard case .corrupt = registry.loadMarker() else {
            return XCTFail("A damaged marker must not read as absent: \(registry.loadMarker())")
        }
        XCTAssertNil(registry.load())
        try registry.clear(matching: UUID())
        XCTAssertThrowsError(try registry.persist(WatchActiveCapture(id: UUID(), startedAt: Date()))) {
            XCTAssertEqual($0 as? WatchActiveCaptureRegistryError, .damagedMarker)
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), damaged)
    }

    func testUnreadableMarker_isReportedAndLeftInPlace() throws {
        let markerURL = try makeMarkerURL()
        // A directory where the file should be cannot be read as data, which
        // stands in for a marker data protection keeps locked.
        try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: false)
        let registry = WatchActiveCaptureRegistry(fileURL: markerURL)

        guard case .unreadable = registry.loadMarker() else {
            return XCTFail("An unreadable marker must not read as absent: \(registry.loadMarker())")
        }
        XCTAssertThrowsError(try registry.persist(WatchActiveCapture(id: UUID(), startedAt: Date())))
        XCTAssertThrowsError(try registry.quarantineCorruptMarker()) {
            XCTAssertEqual($0 as? WatchActiveCaptureRegistryError, .markerNotCorrupt)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testQuarantine_preservesCorruptBytesAndFreesTheMarker() throws {
        let markerURL = try makeMarkerURL()
        let damaged = Data("garbage".utf8)
        try damaged.write(to: markerURL)
        let registry = WatchActiveCaptureRegistry(fileURL: markerURL)

        let preserved = try registry.quarantineCorruptMarker()

        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
        XCTAssertEqual(preserved.deletingLastPathComponent(), markerURL.deletingLastPathComponent())
        XCTAssertNotEqual(preserved, markerURL)
        XCTAssertEqual(registry.loadMarker(), .absent)
        let next = WatchActiveCapture(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.persist(next)
        XCTAssertEqual(registry.load(), next)
        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
    }

    func testQuarantine_refusesAHealthyMarker() throws {
        let registry = WatchActiveCaptureRegistry(fileURL: try makeMarkerURL())
        let capture = WatchActiveCapture(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.persist(capture)

        XCTAssertThrowsError(try registry.quarantineCorruptMarker())
        XCTAssertEqual(registry.load(), capture)
    }
}
