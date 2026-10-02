import Foundation
import XCTest

@testable import SpeakSync

/// The per-device iCloud data sync switch: off must keep History local, with
/// no CloudKit traffic, and on again must catch up on what was saved while off.
/// CloudKit access goes through the recording fakes in
/// `HistorySyncEngineGuardTests`.
@MainActor
final class HistorySyncSwitchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HistorySyncSwitchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testSyncSwitch_defaultsToOnWhenNothingIsStored() {
        let engine = HistorySyncEngine(
            transport: RecordingTransport(), defaults: defaults, cloudAvailable: true
        )

        XCTAssertTrue(engine.isSyncEnabled)
        XCTAssertTrue(SyncConfiguration.isDataSyncEnabled(in: defaults))
    }

    func testSyncWhenSwitchedOff_neverTouchesTransportAndLeavesEntriesPending() async {
        defaults.set(false, forKey: SyncConfiguration.dataSyncEnabledKey)
        let transport = RecordingTransport()
        let delegate = AckingDelegate(entries: [makeEntry(text: "local only")])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: delegate
        )

        await engine.sync()

        XCTAssertFalse(engine.isSyncEnabled)
        XCTAssertNil(engine.state.error, "Off is a choice, not a failure")
        XCTAssertEqual(transport.fetchCount, 0)
        XCTAssertEqual(transport.uploadedBatches.count, 0)
        XCTAssertEqual(delegate.pendingEntries().count, 1)
    }

    func testUploadAndDeleteWhenSwitchedOff_throwWithoutTouchingTransport() async {
        let transport = RecordingTransport()
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true,
            delegate: AckingDelegate(entries: [])
        )
        engine.setSyncEnabled(false)

        do {
            try await engine.upload(entry: makeEntry(text: "local only"))
            XCTFail("Expected HistorySyncDisabledError")
        } catch is HistorySyncDisabledError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        do {
            try await engine.delete(entryID: UUID())
            XCTFail("Expected HistorySyncDisabledError")
        } catch is HistorySyncDisabledError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.uploadedBatches.count, 0)
        XCTAssertEqual(transport.deletedIDs, [])
    }

    func testSwitchingOff_isRememberedForTheNextLaunch() {
        let engine = HistorySyncEngine(
            transport: RecordingTransport(), defaults: defaults, cloudAvailable: true
        )

        XCTAssertNil(engine.setSyncEnabled(false), "Turning sync off starts no work")

        XCTAssertFalse(SyncConfiguration.isDataSyncEnabled(in: defaults))
        let relaunched = HistorySyncEngine(
            transport: RecordingTransport(), defaults: defaults, cloudAvailable: true
        )
        XCTAssertFalse(relaunched.isSyncEnabled)
    }

    func testSwitchingBackOn_uploadsWhatWasSavedWhileOff() async {
        defaults.set(false, forKey: SyncConfiguration.dataSyncEnabledKey)
        let transport = RecordingTransport()
        let saved = makeEntry(text: "saved while off")
        let delegate = AckingDelegate(entries: [saved])
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: delegate
        )

        let resume = engine.setSyncEnabled(true)
        await resume?.value

        XCTAssertTrue(engine.isSyncEnabled)
        XCTAssertTrue(SyncConfiguration.isDataSyncEnabled(in: defaults))
        XCTAssertEqual(transport.fetchCount, 1)
        XCTAssertEqual(transport.uploadedBatches, [[saved.id]])
        XCTAssertTrue(delegate.pendingEntries().isEmpty)
    }

    // MARK: - Helpers

    private func makeEntry(text: String) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: text,
            postProcessedText: nil,
            model: "test",
            duration: 1,
            wordCount: 1,
            originPlatform: "ios",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
