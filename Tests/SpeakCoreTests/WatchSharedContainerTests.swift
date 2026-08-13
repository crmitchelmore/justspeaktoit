import XCTest
@testable import SpeakCore

final class WatchSharedContainerTests: XCTestCase {
    private var scratch: URL!
    private var groupDirectory: URL!
    private var legacyDirectory: URL!
    private var container: WatchSharedContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WatchSharedContainerTests-\(UUID().uuidString)", isDirectory: true)
        groupDirectory = scratch.appendingPathComponent("group", isDirectory: true)
        legacyDirectory = scratch.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        container = WatchSharedContainer(directory: groupDirectory, legacyDirectory: legacyDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - Location

    func testContainer_withoutAnAppGroupFallsBackToTheAppLocalDirectory() {
        // The unprovisioned watch build: the app must keep working, only the
        // complication goes blind.
        let fallback = WatchSharedContainer(directory: legacyDirectory, legacyDirectory: legacyDirectory)

        XCTAssertFalse(fallback.isAppGroupBacked)
        XCTAssertEqual(
            fallback.url(named: "captures.json"),
            legacyDirectory.appendingPathComponent("captures.json")
        )
    }

    func testURL_namesPayloadsInsideTheSharedDirectory() {
        XCTAssertTrue(container.isAppGroupBacked)
        XCTAssertEqual(
            container.url(named: WatchComplicationSnapshot.fileName),
            groupDirectory.appendingPathComponent(WatchComplicationSnapshot.fileName)
        )
    }

    // MARK: - Payload IO

    func testPayloadIO_roundTripsCreatesTheContainerAndClears() {
        XCTAssertNil(container.read(named: "payload.json"))

        container.write(Data("payload".utf8), named: "payload.json")
        XCTAssertEqual(container.read(named: "payload.json"), Data("payload".utf8))

        container.remove(named: "payload.json")
        XCTAssertNil(container.read(named: "payload.json"))
    }

    func testSnapshotAndRequest_travelThroughTheContainerTheWidgetReads() {
        let snapshot = WatchComplicationSnapshot(state: .recording, inFlightCount: 1)
        snapshot.save(in: container)

        XCTAssertEqual(WatchComplicationSnapshot.load(from: container).state, .recording)

        let request = WatchRecordingRequest()
        request.post(in: container)

        XCTAssertEqual(WatchRecordingRequest.consume(from: container)?.id, request.id)
        // Consumed exactly once: a second activation must not re-toggle.
        XCTAssertNil(WatchRecordingRequest.consume(from: container))
    }

    func testStaleRequest_isDiscardedAndStillRemoved() {
        WatchRecordingRequest(requestedAt: Date().addingTimeInterval(-600)).post(in: container)

        XCTAssertNil(WatchRecordingRequest.consume(from: container))
        XCTAssertNil(container.read(named: WatchRecordingRequest.fileName))
    }

    func testSnapshotLoad_isIdleWhenNothingHasBeenPublishedOrThePayloadIsJunk() {
        XCTAssertEqual(WatchComplicationSnapshot.load(from: container), .idle)

        container.write(Data("not json".utf8), named: WatchComplicationSnapshot.fileName)

        XCTAssertEqual(WatchComplicationSnapshot.load(from: container), .idle)
    }

    // MARK: - Migration

    func testMigration_movesAnExistingQueueIntoTheSharedContainer() throws {
        try Data("queue".utf8).write(to: legacyDirectory.appendingPathComponent("captures.json"))

        XCTAssertTrue(container.migrateLegacyFile(named: "captures.json"))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent("captures.json").path)
        )
        XCTAssertEqual(container.read(named: "captures.json"), Data("queue".utf8))
    }

    func testMigration_neverOverwritesTheSharedCopy() throws {
        try Data("stale".utf8).write(to: legacyDirectory.appendingPathComponent("captures.json"))
        container.write(Data("current".utf8), named: "captures.json")

        XCTAssertFalse(container.migrateLegacyFile(named: "captures.json"))

        XCTAssertEqual(container.read(named: "captures.json"), Data("current".utf8))
    }

    func testMigration_isANoOpWithNothingToMoveOrNoAppGroup() throws {
        XCTAssertFalse(container.migrateLegacyFile(named: "captures.json"))

        try Data("queue".utf8).write(to: legacyDirectory.appendingPathComponent("captures.json"))
        let fallback = WatchSharedContainer(directory: legacyDirectory, legacyDirectory: legacyDirectory)

        XCTAssertFalse(fallback.migrateLegacyFile(named: "captures.json"))
        XCTAssertEqual(fallback.read(named: "captures.json"), Data("queue".utf8))
    }
}
