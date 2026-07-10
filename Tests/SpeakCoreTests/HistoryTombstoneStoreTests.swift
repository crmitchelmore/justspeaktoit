import Foundation
import XCTest

@testable import SpeakCore

final class HistoryTombstoneStoreTests: XCTestCase {
    func testStorePersistsAndPrunesAfterNinetyDays() throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("history-sync-tests", isDirectory: true)
        let fileURL = directory.appendingPathComponent("tombstones-\(UUID().uuidString).json")
        let store = HistoryTombstoneStore(fileURL: fileURL, now: { now })
        let fresh = HistoryDeletionTombstone(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            deletedAt: now.addingTimeInterval(-89 * 24 * 60 * 60),
            originDeviceID: "fresh"
        )
        let stale = HistoryDeletionTombstone(
            id: UUID(uuidString: "22222222-2222-3333-4444-555555555555")!,
            deletedAt: now.addingTimeInterval(-91 * 24 * 60 * 60),
            originDeviceID: "stale"
        )

        try store.save([fresh, stale])
        let loaded = store.load()

        XCTAssertEqual(loaded, [fresh])
    }
}
