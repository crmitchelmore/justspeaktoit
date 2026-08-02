import XCTest

@testable import SpeakCore

final class KeyboardHandoffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: KeyboardHandoffStore!
    private var quickStore: KeyboardQuickDictationStore!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardHandoffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = KeyboardHandoffStore(defaults: defaults)
        quickStore = KeyboardQuickDictationStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        quickStore = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testHandoffTransitionsToMatchingConsumableResult() throws {
        let request = try store.createRequest()

        XCTAssertEqual(try store.markRecording(requestID: request.requestID).phase, .recording)
        XCTAssertEqual(try store.markTranscribing(requestID: request.requestID).phase, .transcribing)
        XCTAssertEqual(
            try store.complete(requestID: request.requestID, transcript: "  Insert this text.  ").phase,
            .completed
        )

        XCTAssertEqual(store.consumeResult(requestID: request.requestID), "Insert this text.")
        XCTAssertNil(store.activeRecord())
    }

    func testKeyboardCanRequestFinishBeforeContainingAppTranscribes() throws {
        let request = try store.createRequest()
        try store.markRecording(requestID: request.requestID)

        XCTAssertEqual(try store.requestFinish(requestID: request.requestID).phase, .finishRequested)
        XCTAssertEqual(try store.markTranscribing(requestID: request.requestID).phase, .transcribing)
    }

    func testQuickDictationRequiresFreshHeartbeatInsideReadinessWindow() {
        let now = Date(timeIntervalSince1970: 4_000)
        let session = quickStore.start(now: now, duration: 300)

        XCTAssertEqual(session?.phase, .ready)
        XCTAssertNotNil(quickStore.activeSession(now: now.addingTimeInterval(3)))
        XCTAssertNil(
            quickStore.activeSession(
                now: now.addingTimeInterval(KeyboardQuickDictationStore.heartbeatLifetime + 1)
            )
        )
    }

    func testQuickDictationRecordingCanFinishAfterReadinessWindowExpires() {
        let now = Date(timeIntervalSince1970: 5_000)
        _ = quickStore.start(now: now, duration: 1)
        let recording = quickStore.heartbeat(phase: .recording, now: now.addingTimeInterval(0.5))

        XCTAssertEqual(recording?.phase, .recording)
        XCTAssertNotNil(quickStore.activeSession(now: now.addingTimeInterval(2)))
        XCTAssertEqual(
            quickStore.heartbeat(phase: .ready, now: now.addingTimeInterval(2))?.phase,
            .ready
        )
        XCTAssertNil(quickStore.activeSession(now: now.addingTimeInterval(2)))
    }

    func testMismatchedNonceCannotReadOrClearResult() throws {
        let request = try completedRequest(transcript: "Private result")
        let wrongID = UUID()

        XCTAssertNil(store.record(matching: wrongID))
        XCTAssertNil(store.consumeResult(requestID: wrongID))
        store.clear(requestID: wrongID)

        XCTAssertEqual(store.record(matching: request.requestID)?.transcript, "Private result")
    }

    func testExpiredRequestBecomesTranscriptFreeTimeout() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let request = try store.createRequest(now: now, lifetime: 1)

        let expired = store.record(matching: request.requestID, now: now.addingTimeInterval(2))

        XCTAssertEqual(expired?.phase, .failed)
        XCTAssertEqual(expired?.failureCode, .timedOut)
        XCTAssertNil(expired?.transcript)
        XCTAssertNil(store.consumeResult(requestID: request.requestID, now: now.addingTimeInterval(2)))
    }

    func testCancelRemovesAnyTranscriptAndBlocksCompletion() throws {
        let request = try store.createRequest()
        try store.markRecording(requestID: request.requestID)
        let cancelled = try store.cancel(requestID: request.requestID)

        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.transcript)
        XCTAssertThrowsError(
            try store.markTranscribing(requestID: request.requestID)
        ) { error in
            XCTAssertEqual(error as? KeyboardHandoffStoreError, .invalidTransition)
        }
    }

    func testConsumerInsertsMatchingResultOnce() throws {
        let request = try completedRequest(transcript: "One-time result")
        let consumer = KeyboardHandoffConsumer(store: store)
        var inserted: [String] = []

        XCTAssertTrue(consumer.insertReadyResult(requestID: request.requestID) { inserted.append($0) })
        XCTAssertEqual(inserted, ["One-time result"])
        XCTAssertFalse(consumer.insertReadyResult(requestID: request.requestID) { inserted.append($0) })
        XCTAssertEqual(inserted, ["One-time result"])
    }

    func testFullAccessPolicyGatesSharedHandoff() {
        XCTAssertEqual(
            KeyboardLaunchPolicy.blockReason(hasFullAccess: false, sharedContainerAvailable: true),
            .fullAccessRequired
        )
        XCTAssertEqual(
            KeyboardLaunchPolicy.blockReason(hasFullAccess: true, sharedContainerAvailable: false),
            .sharedContainerUnavailable
        )
        XCTAssertNil(
            KeyboardLaunchPolicy.blockReason(hasFullAccess: true, sharedContainerAvailable: true)
        )
    }

    func testExtensionObservationStoresOnlyAccessMetadata() {
        let now = Date(timeIntervalSince1970: 2_000)
        store.recordExtensionObservation(hasFullAccess: true, now: now)

        XCTAssertEqual(
            store.extensionObservation(),
            KeyboardExtensionObservation(lastSeenAt: now, hadFullAccess: true)
        )
        XCTAssertNil(store.activeRecord())
    }

    func testOnlyRequestedHandoffResumesWhenContainingAppOpens() throws {
        let request = try store.createRequest()

        XCTAssertEqual(
            KeyboardLaunchPolicy.pendingCaptureRequestID(from: store.activeRecord()),
            request.requestID
        )

        try store.markRecording(requestID: request.requestID)
        XCTAssertNil(KeyboardLaunchPolicy.pendingCaptureRequestID(from: store.activeRecord()))
        XCTAssertNil(KeyboardLaunchPolicy.pendingCaptureRequestID(from: nil))
    }

    func testUndoPlanRequiresExactInsertedSuffix() {
        XCTAssertEqual(
            KeyboardCorrectionPlan.undoDeletionCount(
                insertedText: "Correct this 👋",
                documentContextBeforeInput: "Prefix. Correct this 👋"
            ),
            14
        )
        XCTAssertNil(
            KeyboardCorrectionPlan.undoDeletionCount(
                insertedText: "Correct this 👋",
                documentContextBeforeInput: "Correct this changed"
            )
        )
        XCTAssertNil(
            KeyboardCorrectionPlan.undoDeletionCount(
                insertedText: "",
                documentContextBeforeInput: "Prefix"
            )
        )
    }

    private func completedRequest(transcript: String) throws -> KeyboardHandoffRecord {
        let request = try store.createRequest()
        try store.markRecording(requestID: request.requestID)
        try store.markTranscribing(requestID: request.requestID)
        return try store.complete(requestID: request.requestID, transcript: transcript)
    }
}
