#if os(iOS)
import Foundation
import XCTest
@testable import SpeakiOSLib

final class IOSHistoryRevisionLedgerTests: XCTestCase {
    private func item(_ id: UUID = UUID()) -> iOSHistoryItem {
        iOSHistoryItem(id: id, transcription: "words", model: "test/model", duration: 1, wordCount: 1)
    }

    private func result(
        revision: UInt64, versions: [UUID: UInt64] = [:], durableVersions: [UUID: UInt64]? = nil
    ) -> IOSHistoryPersistence.Result {
        IOSHistoryPersistence.Result(
            revision: revision, rows: [], versions: versions, durableVersions: durableVersions ?? versions,
            durable: true, isReady: true, errorMessage: nil, recoveredIDs: [], removedIDs: [],
            remoteAcknowledgedIDs: [], remoteNewerLocalIDs: []
        )
    }

    func testAdmit_stampsEachOperationWithTheNextRevision() {
        var ledger = IOSHistoryRevisionLedger()
        XCTAssertEqual(ledger.admit(.load), 1)
        XCTAssertEqual(ledger.admit(.upsert(item())), 2)
        XCTAssertEqual(ledger.admit(.commit), 3)
        XCTAssertEqual(ledger.revision, 3)
    }

    func testIsUnchanged_falseOnlyForTheRowMutatedAfterTheReceipt() {
        let id = UUID()
        let other = UUID()
        var ledger = IOSHistoryRevisionLedger()
        let receipt = ledger.admit(.upsert(item(id)))
        XCTAssertTrue(ledger.isUnchanged(id, since: receipt))

        _ = ledger.admit(.processed(id, "polished", nil))
        XCTAssertFalse(ledger.isUnchanged(id, since: receipt))
        XCTAssertTrue(ledger.isUnchanged(other, since: receipt))
        // Reads and retries never supersede a receipt.
        let later = ledger.admit(.retry)
        XCTAssertTrue(ledger.isUnchanged(id, since: later))
    }

    func testAccept_refusesAResultOlderThanThePublishedSnapshot() {
        let id = UUID()
        var ledger = IOSHistoryRevisionLedger()
        XCTAssertTrue(ledger.accept(result(revision: 4, versions: [id: 2])))
        XCTAssertFalse(ledger.accept(result(revision: 3, versions: [id: 1])))
        XCTAssertEqual(ledger.publishedRevision, 4)
        XCTAssertEqual(ledger.versions, [id: 2])
        // An equal revision is still adopted.
        XCTAssertTrue(ledger.accept(result(revision: 4, versions: [id: 3])))
        XCTAssertEqual(ledger.versions, [id: 3])
    }

    func testIsCurrent_needsMatchingDurableVersionAndNoLaterMutationOrClear() {
        let id = UUID()
        var ledger = IOSHistoryRevisionLedger()
        let receipt = ledger.admit(.upsert(item(id)))
        _ = ledger.accept(result(revision: receipt, versions: [id: 1], durableVersions: [id: 0]))
        XCTAssertFalse(ledger.isCurrent(id, version: 1, receiptRevision: receipt), "not yet durable")

        _ = ledger.accept(result(revision: receipt, versions: [id: 1]))
        XCTAssertTrue(ledger.isCurrent(id, version: 1, receiptRevision: receipt))
        XCTAssertFalse(ledger.isCurrent(id, version: 2, receiptRevision: receipt))

        _ = ledger.admit(.clear)
        XCTAssertFalse(ledger.isCurrent(id, version: 1, receiptRevision: receipt), "a later clear supersedes")
    }

    func testOwnsMutation_aNewerPublishedSnapshotMustAgreeOnTheVersion() {
        let id = UUID()
        var ledger = IOSHistoryRevisionLedger()
        let first = ledger.admit(.upsert(item(id)))
        let older = result(revision: first, versions: [id: 1])
        XCTAssertTrue(ledger.ownsMutation(id, result: older))

        _ = ledger.admit(.load)
        _ = ledger.accept(result(revision: 2, versions: [id: 1]))
        XCTAssertTrue(ledger.ownsMutation(id, result: older), "the newer snapshot still shows this version")
        _ = ledger.accept(result(revision: 2, versions: [id: 5]))
        XCTAssertFalse(ledger.ownsMutation(id, result: older))

        let mutated = ledger.admit(.error(id, "failed"))
        XCTAssertFalse(ledger.ownsMutation(id, result: result(revision: mutated - 1, versions: [id: 5])))
    }

    func testOwnsDeletion_aLaterReinsertionOrVisibleNewerSnapshotKeepsTheRow() {
        let id = UUID()
        var ledger = IOSHistoryRevisionLedger()
        _ = ledger.admit(.upsert(item(id)))
        let removal = result(revision: ledger.admit(.remove(id)))
        XCTAssertTrue(ledger.ownsDeletion(id, result: removal, isVisible: false))

        _ = ledger.accept(result(revision: removal.revision + 1))
        XCTAssertTrue(ledger.ownsDeletion(id, result: removal, isVisible: false))
        XCTAssertFalse(ledger.ownsDeletion(id, result: removal, isVisible: true))

        _ = ledger.admit(.remote(item(id)))
        XCTAssertFalse(ledger.ownsDeletion(id, result: removal, isVisible: false), "re-inserted after removal")
    }

    func testOwnsDeletion_doesNotReadVisibilityUnlessANewerSnapshotIsPublished() {
        let id = UUID()
        var ledger = IOSHistoryRevisionLedger()
        let removal = result(revision: ledger.admit(.remoteDelete(id)))
        XCTAssertTrue(ledger.ownsDeletion(id, result: removal, isVisible: {
            XCTFail("visibility only matters once a newer snapshot is on screen")
            return true
        }()))
    }

    func testHasNoInsertion_onlyAfterEveryInsertionPrecedesTheClear() {
        var ledger = IOSHistoryRevisionLedger()
        _ = ledger.admit(.upsert(item()))
        let clear = ledger.admit(.clear)
        XCTAssertTrue(ledger.hasNoInsertion(after: clear))
        // A replacement or status update is not an insertion.
        _ = ledger.admit(.replaceIfUntouched(item(), fingerprint: "f", filedAt: Date()))
        XCTAssertTrue(ledger.hasNoInsertion(after: clear))
        _ = ledger.admit(.remote(item()))
        XCTAssertFalse(ledger.hasNoInsertion(after: clear))
    }
}

final class IOSHistoryRemoteLedgerTests: XCTestCase {
    func testFinishCommit_returnsPendingAndKeepsOnlyNewerAcknowledgements() {
        let settled = UUID()
        let newer = UUID()
        var ledger = IOSHistoryRemoteLedger()
        ledger.recordAcknowledged(settled, version: 3)
        ledger.recordAcknowledged(settled, version: 2)
        ledger.recordAcknowledged(newer, version: 9)

        XCTAssertEqual(ledger.finishCommit(revision: 5, target: 0), [settled: 3, newer: 9])
        XCTAssertEqual(ledger.finishCommit(revision: 5, target: 0), [newer: 9])
    }

    func testFinishCommit_clearsTheUncommittedRevisionOnlyForItsOwnTarget() {
        var ledger = IOSHistoryRemoteLedger()
        ledger.recordUncommitted(4)
        ledger.recordUncommitted(2)
        XCTAssertEqual(ledger.uncommittedRevision, 4)

        _ = ledger.finishCommit(revision: 4, target: 2)
        XCTAssertEqual(ledger.uncommittedRevision, 4, "a commit started for an older target leaves it")
        _ = ledger.finishCommit(revision: 4, target: 4)
        XCTAssertEqual(ledger.uncommittedRevision, 0)
    }

    func testOffer_keepsTheFirstVersionUntilConsumed() {
        let id = UUID()
        var ledger = IOSHistoryRemoteLedger()
        ledger.offer(id, version: 1)
        ledger.offer(id, version: 2)
        XCTAssertEqual(ledger.unraced(offersAmong: [id]), [id: 1])

        XCTAssertFalse(ledger.consume(id, version: 2))
        XCTAssertTrue(ledger.consume(id, version: 1))
        XCTAssertFalse(ledger.consume(id, version: 1), "an offer is consumed once")
        ledger.offer(id, version: 2)
        XCTAssertEqual(ledger.unraced(offersAmong: [id]), [id: 2])
    }

    func testDirectUploads_holdOffersUntilEveryRacingUploadEnds() {
        let id = UUID()
        let other = UUID()
        var ledger = IOSHistoryRemoteLedger()
        ledger.offer(id, version: 1)
        ledger.offer(other, version: 1)
        ledger.beginDirectUpload(id)
        ledger.beginDirectUpload(id)

        XCTAssertEqual(ledger.unraced(offersAmong: [id, other]), [other: 1])
        XCTAssertEqual(ledger.unraced(offersAmong: [id]), [:])
        XCTAssertFalse(ledger.consume(id, version: 1))

        ledger.endDirectUpload(id)
        XCTAssertFalse(ledger.consume(id, version: 1), "one upload is still racing")
        ledger.endDirectUpload(id)
        XCTAssertTrue(ledger.consume(id, version: 1))
    }
}
#endif
