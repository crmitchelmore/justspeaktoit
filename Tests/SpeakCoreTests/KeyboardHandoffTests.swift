import XCTest

@testable import SpeakCore

final class KeyboardHandoffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: KeyboardHandoffStore!
    private var instantStore: KeyboardInstantDictationStore!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardHandoffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = KeyboardHandoffStore(defaults: defaults)
        instantStore = KeyboardInstantDictationStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        instantStore = nil
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

    func testHandoffKeepsTheExactSelectedProfileThroughEveryTransition() throws {
        let selection = KeyboardDictationProfileCatalog.selection(
            for: KeyboardAppProfileConfiguration(
                transcriptionMode: .batch,
                transcriptionModelIdentifier: "openai/gpt-transcribe",
                languageIdentifier: "en_GB",
                postProcessingEnabled: true,
                postProcessingModelIdentifier: "openai/gpt-5-mini"
            )
        )
        let profile = selection.selectedProfile
        let request = try store.createRequest(profile: profile)

        let switchedSelection = selection.selecting(KeyboardDictationProfileCatalog.directIdentifier)

        XCTAssertEqual(switchedSelection.selectedProfile.route, .directAppleSpeech)
        XCTAssertEqual(request.profile, profile)
        XCTAssertEqual(try store.markRecording(requestID: request.requestID).profile, profile)
        XCTAssertEqual(try store.updateInterim(requestID: request.requestID, transcript: "Text").profile, profile)
        XCTAssertEqual(try store.requestFinish(requestID: request.requestID).profile, profile)
        XCTAssertEqual(try store.markTranscribing(requestID: request.requestID).profile, profile)
        XCTAssertEqual(try store.complete(requestID: request.requestID, transcript: "Text").profile, profile)
    }

    func testKeyboardCanRequestFinishBeforeContainingAppTranscribes() throws {
        let request = try store.createRequest()
        try store.markRecording(requestID: request.requestID)

        XCTAssertEqual(try store.requestFinish(requestID: request.requestID).phase, .finishRequested)
        XCTAssertEqual(try store.markTranscribing(requestID: request.requestID).phase, .transcribing)
    }

    func testInstantDictationRequiresFreshHeartbeat() {
        let now = Date(timeIntervalSince1970: 4_000)
        instantStore.setEnabled(true)
        let session = instantStore.start(now: now)

        XCTAssertEqual(session?.phase, .ready)
        XCTAssertNotNil(instantStore.activeSession(now: now.addingTimeInterval(3)))
        XCTAssertNil(
            instantStore.activeSession(
                now: now.addingTimeInterval(KeyboardInstantDictationStore.heartbeatLifetime + 1)
            )
        )
        XCTAssertNotNil(
            instantStore.heartbeat(
                now: now.addingTimeInterval(KeyboardInstantDictationStore.heartbeatLifetime + 1)
            )
        )
    }

    func testInstantDictationOwnerCanClearStaleSession() {
        let now = Date(timeIntervalSince1970: 4_500)
        instantStore.setEnabled(true)
        _ = instantStore.start(now: now)
        let staleTime = now.addingTimeInterval(KeyboardInstantDictationStore.heartbeatLifetime + 1)

        XCTAssertNil(instantStore.activeSession(now: staleTime, clearingStaleRecord: true))
        XCTAssertNil(instantStore.heartbeat(now: staleTime))
    }

    func testInstantDictationHasNoFixedReadinessWindow() {
        let now = Date(timeIntervalSince1970: 5_000)
        instantStore.setEnabled(true)
        _ = instantStore.start(now: now)
        let recording = instantStore.heartbeat(phase: .recording, now: now.addingTimeInterval(0.5))

        XCTAssertEqual(recording?.phase, .recording)
        XCTAssertNotNil(instantStore.activeSession(now: now.addingTimeInterval(2)))
        XCTAssertEqual(
            instantStore.heartbeat(phase: .ready, now: now.addingTimeInterval(2))?.phase,
            .ready
        )
        XCTAssertNotNil(instantStore.activeSession(now: now.addingTimeInterval(2)))
    }

    func testInstantDictationPreferencePersistsUntilDisabled() {
        XCTAssertFalse(instantStore.isEnabled)

        instantStore.setEnabled(true)
        _ = instantStore.start()

        XCTAssertTrue(instantStore.isEnabled)
        XCTAssertNotNil(instantStore.activeSession())

        instantStore.setEnabled(false)

        XCTAssertFalse(instantStore.isEnabled)
        XCTAssertNil(instantStore.activeSession())
    }

    func testInstantDictationStartIsRejectedWhileDisabled() {
        XCTAssertFalse(instantStore.isEnabled)

        XCTAssertNil(instantStore.start())
        XCTAssertNil(instantStore.activeSession())
    }

    func testInstantDictationStartCanEnableAtomically() {
        XCTAssertFalse(instantStore.isEnabled)

        let session = instantStore.start(enabling: true)

        XCTAssertNotNil(session)
        XCTAssertTrue(instantStore.isEnabled)
        XCTAssertNotNil(instantStore.activeSession())

        instantStore.setEnabled(false)

        XCTAssertFalse(instantStore.isEnabled)
        XCTAssertNil(instantStore.activeSession())
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

    func testLiveTranscriptUsesReplacementSemanticsAndClearsAtCompletion() throws {
        let request = try store.createRequest()
        try store.markRecording(requestID: request.requestID)

        XCTAssertEqual(
            try store.updateInterim(requestID: request.requestID, transcript: "First words").interimTranscript,
            "First words"
        )
        XCTAssertEqual(
            try store.updateInterim(requestID: request.requestID, transcript: "Full current turn").interimTranscript,
            "Full current turn"
        )
        XCTAssertEqual(
            try store.markTranscribing(requestID: request.requestID).interimTranscript,
            "Full current turn"
        )
        XCTAssertNil(
            try store.complete(requestID: request.requestID, transcript: "Final text").interimTranscript
        )
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
