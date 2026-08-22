import XCTest

@testable import SpeakCore

/// Result delivery and expiry for the keyboard handoff (issue #712): results
/// are consumed only by their own document, the consumer never clears a
/// transcript before it has been inserted, and a timed-out record keeps a
/// fixed expiry instead of being extended by every read.
final class KeyboardHandoffResultTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: KeyboardHandoffStore!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardHandoffResultTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = KeyboardHandoffStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTimedOutRecord_keepsAFixedExpiryAcrossReadsAndThenDisappears() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let request = try store.createRequest(now: now, lifetime: 1)
        let storedExpiry = now.addingTimeInterval(1)
        let timedOutExpiry = storedExpiry.addingTimeInterval(KeyboardHandoffStore.resultLifetime)

        // Reading the timed-out view repeatedly must not push its expiry out:
        // it is anchored to the stored expiry, not to the read time.
        let first = store.record(matching: request.requestID, now: storedExpiry.addingTimeInterval(10))
        let later = store.record(matching: request.requestID, now: storedExpiry.addingTimeInterval(40))
        XCTAssertEqual(first?.failureCode, .timedOut)
        XCTAssertEqual(first?.expiresAt, timedOutExpiry)
        XCTAssertEqual(later?.expiresAt, timedOutExpiry)
        XCTAssertEqual(first?.updatedAt, storedExpiry)

        // Once the result lifetime has passed, the timed-out record is gone.
        XCTAssertNil(store.record(matching: request.requestID, now: timedOutExpiry))
        XCTAssertNil(store.record(matching: request.requestID, now: timedOutExpiry.addingTimeInterval(3_600)))
    }

    func testResultCanOnlyBeConsumedByItsOriginalTextDocument() throws {
        let target = UUID()
        let request = try store.createRequest(targetDocumentIdentifier: target)
        try store.markRecording(requestID: request.requestID)
        try store.markTranscribing(requestID: request.requestID)
        try store.complete(requestID: request.requestID, transcript: "Right field")

        XCTAssertNil(
            store.consumeResult(requestID: request.requestID, documentIdentifier: UUID())
        )
        XCTAssertEqual(
            store.consumeResult(requestID: request.requestID, documentIdentifier: target),
            "Right field"
        )
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

    func testConsumerClearsTheResultOnlyAfterInsertingIt() throws {
        let request = try completedRequest(transcript: "Keep until inserted")
        let consumer = KeyboardHandoffConsumer(store: store)
        var transcriptStillStoredDuringInsert: String?

        XCTAssertTrue(consumer.insertReadyResult(requestID: request.requestID) { _ in
            // If the extension died here, the next launch must still find it.
            transcriptStillStoredDuringInsert = store.readyResult(requestID: request.requestID)
        })

        XCTAssertEqual(transcriptStillStoredDuringInsert, "Keep until inserted")
        XCTAssertNil(store.readyResult(requestID: request.requestID))
        XCTAssertNil(store.activeRecord())
    }

    func testReadyResultLeavesTheRecordInPlace() throws {
        let request = try completedRequest(transcript: "Readable twice")

        XCTAssertEqual(store.readyResult(requestID: request.requestID), "Readable twice")
        XCTAssertEqual(store.readyResult(requestID: request.requestID), "Readable twice")
        XCTAssertEqual(store.consumeResult(requestID: request.requestID), "Readable twice")
        XCTAssertNil(store.readyResult(requestID: request.requestID))
    }

    private func completedRequest(transcript: String) throws -> KeyboardHandoffRecord {
        let request = try store.createRequest()
        try store.markRecording(requestID: request.requestID)
        try store.markTranscribing(requestID: request.requestID)
        return try store.complete(requestID: request.requestID, transcript: transcript)
    }
}
