#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Issue #992. The store is the only thing that survives the crash, so what is
/// proved here is that a claim written by one "process" reads back correctly in
/// another, and that the store's own lifecycle never loses a recoverable
/// capture or offers a live one.
final class CaptureSafetyClaimStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let firstProcess = UUID()
    private let secondProcess = UUID()

    override func setUp() {
        super.setUp()
        suiteName = "CaptureSafetyClaimStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func store(owner: UUID) -> CaptureSafetyClaimStore {
        CaptureSafetyClaimStore(defaults: defaults, owner: owner)
    }

    func testAClaimOpenedByOneProcessIsReadableByTheNext() {
        let recording = UUID()
        let opened = Date(timeIntervalSince1970: 1_700_000_000)
        store(owner: firstProcess).open(
            recording: recording,
            fileName: "Recording-A.m4a",
            startedAt: opened,
            now: opened
        )

        let claims = store(owner: secondProcess).claims()
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.run, recording)
        XCTAssertEqual(claims.first?.owner, firstProcess)
        XCTAssertEqual(claims.first?.startedAt, opened)
        XCTAssertEqual(claims.first?.deliveredTranscript, false)
    }

    func testAClaimThatOutlivesItsProcessIsRecoverableToTheNextLaunch() {
        // The whole feature in one test: a capture starts, its process dies
        // before the transcript is saved, and the next launch finds the audio.
        let recording = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        store(owner: firstProcess).open(
            recording: recording,
            fileName: "Recording-A.m4a",
            startedAt: started,
            now: started
        )

        let plan = CaptureRecoveryScanner.scan(CaptureRecoveryInput(
            claims: store(owner: secondProcess).claims(),
            files: [CaptureSafetyFile(fileName: "Recording-A.m4a", byteSize: 400_000)],
            currentOwner: secondProcess,
            now: started.addingTimeInterval(3600)
        ))
        XCTAssertEqual(plan.recoverable.map(\.run), [recording])
    }

    func testDeliveryMarkingOnlyTouchesThisProcessesOwnClaims() {
        let mine = UUID()
        let theirs = UUID()
        let now = Date()
        store(owner: firstProcess).open(recording: mine, fileName: "mine.m4a", startedAt: now, now: now)
        store(owner: secondProcess).open(recording: theirs, fileName: "theirs.m4a", startedAt: now, now: now)

        store(owner: firstProcess).markDeliveredForThisProcess()

        let claims = Dictionary(
            uniqueKeysWithValues: store(owner: firstProcess).claims().map { ($0.run, $0) }
        )
        XCTAssertEqual(claims[mine]?.deliveredTranscript, true)
        XCTAssertEqual(
            claims[theirs]?.deliveredTranscript,
            false,
            "this process cannot know what became of another process's transcript"
        )
    }

    func testACaptureStillWritingKeepsItsClaimWhenAnotherIsDelivered() {
        let finished = UUID()
        let stillWriting = UUID()
        let now = Date()
        let store = self.store(owner: firstProcess)
        store.open(recording: finished, fileName: "a.m4a", startedAt: now, now: now)
        store.open(recording: stillWriting, fileName: "b.m4a", startedAt: now, now: now)

        store.markDeliveredForThisProcess(excluding: [stillWriting])

        let claims = Dictionary(uniqueKeysWithValues: store.claims().map { ($0.run, $0) })
        XCTAssertEqual(claims[finished]?.deliveredTranscript, true)
        XCTAssertEqual(claims[stillWriting]?.deliveredTranscript, false)
    }

    func testHeartbeatMovesOnlyTheNamedClaim() {
        let one = UUID()
        let two = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = self.store(owner: firstProcess)
        store.open(recording: one, fileName: "a.m4a", startedAt: start, now: start)
        store.open(recording: two, fileName: "b.m4a", startedAt: start, now: start)

        store.heartbeat(recording: one, now: start.addingTimeInterval(30))

        let claims = Dictionary(uniqueKeysWithValues: store.claims().map { ($0.run, $0) })
        XCTAssertEqual(claims[one]?.lastHeartbeat, start.addingTimeInterval(30))
        XCTAssertEqual(claims[two]?.lastHeartbeat, start)
    }

    func testHeartbeatingAnUnknownRecordingDoesNotInventAClaim() {
        let store = self.store(owner: firstProcess)
        store.heartbeat(recording: UUID())
        XCTAssertTrue(store.claims().isEmpty)
    }

    func testReopeningTheSameRecordingReplacesItsClaimRatherThanDuplicating() {
        let recording = UUID()
        let store = self.store(owner: firstProcess)
        store.open(recording: recording, fileName: "a.m4a", startedAt: Date())
        store.open(recording: recording, fileName: "a.m4a", startedAt: Date())
        XCTAssertEqual(store.claims().count, 1)
    }

    func testForgettingRemovesOnlyTheNamedRecord() {
        let keep = UUID()
        let drop = UUID()
        let store = self.store(owner: firstProcess)
        store.open(recording: keep, fileName: "a.m4a", startedAt: Date())
        store.open(recording: drop, fileName: "b.m4a", startedAt: Date())
        store.forget(recording: drop)
        XCTAssertEqual(store.claims().map(\.run), [keep])
    }

    func testAnUndecodableRecordReportsNoClaimsRatherThanPartialOnes() {
        // Acting on half a picture could offer a live capture for recovery.
        defaults.set(Data("not json".utf8), forKey: "captureSafetyClaims.v1")
        XCTAssertTrue(store(owner: firstProcess).claims().isEmpty)
    }

    func testTheOutcomeJournalNarrowsEveryCaptureErrorToAClosedLabel() {
        XCTAssertEqual(
            CaptureOutcomeJournal.outcome(for: iOSTranscriptionError.startTimedOut(after: .engineStarted)),
            .startFailed
        )
        XCTAssertEqual(
            CaptureOutcomeJournal.outcome(for: iOSTranscriptionError.microphoneDeliveredNoAudio),
            .noInput
        )
        XCTAssertEqual(
            CaptureOutcomeJournal.outcome(for: iOSTranscriptionError.finalisationTimedOut),
            .finalisationTimedOut
        )
        XCTAssertEqual(CaptureOutcomeJournal.outcome(for: CancellationError()), .cancelled)
        // An unnamed failure is reported as a failure, never guessed into one
        // of the named bounds.
        XCTAssertEqual(
            CaptureOutcomeJournal.outcome(for: NSError(domain: "x", code: 1)),
            .failed
        )
    }
}
#endif
