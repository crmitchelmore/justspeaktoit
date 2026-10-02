import Foundation
import SpeakCore
import SpeakDesktop
import SpeakSync
import SpeakTestSupport
import XCTest

@testable import SpeakDesktopSync

/// A remote History change this device cannot save must not be skipped: the
/// pass fails before its cursor passes the change, and a later pass applies it.
final class DesktopCloudSyncReplayTests: DesktopCloudSyncTestCase {
    func testARemoteChangeThatCannotBeSavedHoldsTheCursorUntilALaterPassSavesIt() async throws {
        let macID = UUID()
        seedMacHistory(server, id: macID, raw: "saved on the second pass", updatedAt: fixtureDate(50))
        let blocker = try blockRecord(macID)
        let changes = ChangeLog()
        let (service, state) = try await signedInService { await changes.append($0) }

        let failed = await service.sync()

        XCTAssertEqual(failed.error, DesktopCloudSyncError.historyChangesNotSaved(1).localizedDescription)
        let unsaved = await records.existingRecord(id: macID)
        XCTAssertNil(unsaved)
        let heldCursor = await state.current.historyCursor
        XCTAssertNil(heldCursor, "the cursor passed a change that was never saved")

        try FileManager.default.removeItem(at: blocker)
        let replayed = await service.sync()

        XCTAssertNil(replayed.error)
        let saved = try await records.record(id: macID)
        XCTAssertEqual(saved.result?.text, "saved on the second pass")
        let applied = await changes.all
        XCTAssertEqual(applied, [.saved(macID)])
        let cursor = await state.current.historyCursor
        XCTAssertNotNil(cursor)
    }

    /// One page per request: the page saved before the failure keeps its
    /// cursor, and the next pass resumes there instead of starting over.
    func testALaterPageThatCannotBeSavedResumesAfterTheCommittedPages() async throws {
        server.setPageLimit(1)
        let firstID = UUID()
        let blockedID = UUID()
        seedMacHistory(server, id: firstID, raw: "first page", updatedAt: fixtureDate(50))
        seedMacHistory(server, id: blockedID, raw: "second page", updatedAt: fixtureDate(60))
        let blocker = try blockRecord(blockedID)
        let changes = ChangeLog()
        let recorder = RecordingServerTransport(server: server)
        let (service, state) = try await signedInService(transport: recorder) { await changes.append($0) }

        let failed = await service.sync()

        XCTAssertEqual(failed.error, DesktopCloudSyncError.historyChangesNotSaved(1).localizedDescription)
        let firstCursor = await state.current.historyCursor
        // The web cursor is the server's syncToken as UTF-8.
        let firstPage = try XCTUnwrap(firstCursor.flatMap { String(data: $0, encoding: .utf8) })
        let appliedFirst = await changes.all
        XCTAssertEqual(appliedFirst, [.saved(firstID)])

        try FileManager.default.removeItem(at: blocker)
        let sentBefore = await recorder.sent.count
        let replayed = await service.sync()

        XCTAssertNil(replayed.error)
        let sent = await recorder.sent.dropFirst(sentBefore)
        let feed = try XCTUnwrap(sent.first { $0.operation == "private/changes/zone" })
        XCTAssertTrue(feed.body.contains("\"\(firstPage)\""), "the next pass resumes after the committed page")
        let applied = await changes.all
        XCTAssertEqual(applied, [.saved(firstID), .saved(blockedID)])
        let saved = try await records.record(id: blockedID)
        XCTAssertEqual(saved.result?.text, "second page")
    }

    /// A record file that can never be read is kept, as a recording made here
    /// would be, so it cannot hold the cursor for good.
    func testARemoteDeletionOfAnUnreadableRecordKeepsItAndSyncMovesOn() async throws {
        let unreadableID = UUID()
        seedMacHistory(server, id: unreadableID, raw: "becomes unreadable", updatedAt: fixtureDate(50))
        let (service, state) = try await signedInService()
        _ = await service.sync()
        let file = historyDirectory.appendingPathComponent(unreadableID.uuidString + ".json")
        try Data("not a record".utf8).write(to: file)

        server.seedDeletion(zone: syncZone, recordName: unreadableID.uuidString)
        let laterID = UUID()
        seedMacHistory(server, id: laterID, raw: "after the deletion", updatedAt: fixtureDate(60))
        let report = await service.sync()

        XCTAssertNil(report.error)
        XCTAssertEqual(try Data(contentsOf: file), Data("not a record".utf8), "the unreadable file is left alone")
        let kept = await state.current.history[unreadableID]
        XCTAssertEqual(kept?.deletedElsewhere, true, "it is never uploaded again")
        let later = await records.existingRecord(id: laterID)
        XCTAssertNotNil(later)
    }

    // MARK: - The store's commit

    func testADeletionWhoseSyncStateCannotBeSavedFailsTheCommitAndIsReplayed() async throws {
        let changes = ChangeLog()
        let (store, state) = try makeStore(reportingTo: changes)
        let copy = SyncableHistoryEntry(
            id: UUID(), createdAt: fixtureDate(0), rawTranscription: "synced in", postProcessedText: nil,
            model: "deepgram/nova-3", duration: 1, wordCount: 2, originPlatform: "macos", updatedAt: fixtureDate(50)
        )
        await store.didReceiveRemoteEntry(copy)
        try await store.persistRemoteChanges()
        let blocker = try blockState()

        await store.didDeleteRemoteEntry(id: copy.id)
        do {
            try await store.persistRemoteChanges()
            XCTFail("a deletion whose state was not saved must fail the commit")
        } catch let error as DesktopCloudSyncError {
            XCTAssertEqual(error, .historyChangesNotSaved(1))
        }

        try FileManager.default.removeItem(at: blocker)
        await store.didDeleteRemoteEntry(id: copy.id)
        try await store.persistRemoteChanges()
        let reported = await changes.all
        XCTAssertEqual(reported, [.saved(copy.id), .removed(copy.id)])
        let entry = await state.current.history[copy.id]
        XCTAssertNil(entry)
    }

    func testTheCommitReportsWhatWasSavedBeforeFailingForWhatWasNot() async throws {
        let changes = ChangeLog()
        let (store, _) = try makeStore(reportingTo: changes)
        let saved = remoteEntry(raw: "saved")
        let blocked = remoteEntry(raw: "blocked")
        _ = try blockRecord(blocked.id)

        await store.didReceiveRemoteEntry(saved)
        await store.didReceiveRemoteEntry(blocked)
        do {
            try await store.persistRemoteChanges()
            XCTFail("an unsaved change must fail the commit")
        } catch let error as DesktopCloudSyncError {
            XCTAssertEqual(error, .historyChangesNotSaved(1))
        }
        let reported = await changes.all
        XCTAssertEqual(reported, [.saved(saved.id)])

        // Reported once: the next commit has nothing left over.
        try await store.persistRemoteChanges()
    }

    /// A pass stopped between a change it could not save and its commit saved
    /// no cursor past the change; the next pass must not fail for it.
    func testAFailureLeftByAStoppedPassDoesNotFailTheNextPass() async throws {
        let (store, _) = try makeStore(reportingTo: ChangeLog())
        let blocked = remoteEntry(raw: "blocked")
        _ = try blockRecord(blocked.id)
        await store.didReceiveRemoteEntry(blocked)

        await store.beginPass()

        try await store.persistRemoteChanges()
    }

    // MARK: - Helpers

    /// Where the fixture's recording store keeps its records.
    private var historyDirectory: URL { directory.appendingPathComponent("History") }

    private func makeStore(
        reportingTo changes: ChangeLog
    ) throws -> (DesktopHistorySyncStore, DesktopCloudSyncStateStore) {
        let state = try DesktopCloudSyncStateStore(url: stateURL)
        let store = DesktopHistorySyncStore(records: records, state: state) { await changes.append($0) }
        return (store, state)
    }

    private func remoteEntry(raw: String) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: UUID(), createdAt: fixtureDate(0), rawTranscription: raw, postProcessedText: nil,
            model: "deepgram/nova-3", duration: 1, wordCount: 1, originPlatform: "macos", updatedAt: fixtureDate(50)
        )
    }

    /// Occupies a record's file with a non-empty directory, so saving it fails
    /// the way a full or failing disk would, until the directory is removed.
    private func blockRecord(_ id: UUID) throws -> URL {
        let blocker = historyDirectory.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.createDirectory(
            at: blocker.appendingPathComponent("occupied"), withIntermediateDirectories: true
        )
        return blocker
    }

    /// Makes the sync state file unwritable the same way; what the state
    /// store holds in memory stays.
    private func blockState() throws -> URL {
        let url = stateURL
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("occupied"), withIntermediateDirectories: true
        )
        return url
    }
}
