#if os(iOS)
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// The foreground coordinator's owned collaborators, exercised without the
/// coordinator: run ownership, route resolution and stop settlement.
@MainActor
final class ForegroundRunCollaboratorTests: XCTestCase {
    // MARK: Run owner

    func testOwner_claimsOnceAndGatesCallbacksToTheCurrentRunAndSession() throws {
        let ownership = ForegroundRecordingOwnership()
        var released: [UUID] = []
        let owner = ForegroundRunOwner(ownership: ownership) { released.append($0) }
        let handle = ForegroundCaptureHandle()
        let runID = try XCTUnwrap(owner.claim(binding: handle))
        XCTAssertNil(owner.claim(binding: nil), "One run owns capture at a time")
        XCTAssertTrue(ownership.isOwned)
        XCTAssertTrue(owner.owns(handle))

        let session = ForegroundTestSession(), stranger = ForegroundTestSession()
        try owner.adoptStarting(session, run: runID)
        XCTAssertTrue(owner.accepts(runID, session: session))
        XCTAssertFalse(owner.accepts(runID, session: stranger))
        XCTAssertFalse(owner.accepts(UUID(), session: session))

        owner.noteStarted(session)
        try owner.activate(runID)
        XCTAssertEqual(owner.phase, .recording)
        XCTAssertTrue(owner.accepts(runID, session: session))

        XCTAssertTrue(owner.beginStopping())
        XCTAssertTrue(owner.takeForStop() === session)
        XCTAssertTrue(owner.stillOwnsStop(of: session))
        XCTAssertTrue(owner.endStop(of: session))
        owner.finishStopping()
        XCTAssertEqual(released, [runID])
        XCTAssertFalse(ownership.isOwned)
        XCTAssertFalse(owner.owns(handle), "A settled run's handle owns nothing")
    }

    func testOwner_failureWhileStartingIsHeldForActivationNotPublished() throws {
        let owner = ForegroundRunOwner(ownership: ForegroundRecordingOwnership()) { _ in }
        let runID = try XCTUnwrap(owner.claim(binding: nil))
        let session = ForegroundTestSession()
        var failures = 0
        owner.bind(session, run: runID, to: .init(
            partial: { _, _, _ in }, warning: { _ in },
            failure: { _, _ in failures += 1 }, firstInput: {}
        ))
        try owner.adoptStarting(session, run: runID)
        session.onError?(iOSTranscriptionError.microphoneChanged)
        session.onError?(CancellationError())
        XCTAssertEqual(failures, 0)
        XCTAssertThrowsError(try owner.activate(runID)) {
            guard case .microphoneChanged? = $0 as? iOSTranscriptionError else { return XCTFail("\($0)") }
        }
    }

    func testOwner_cancelDuringStopRetiresTheDrainAndSettlesBeforeRelease() async throws {
        let owner = ForegroundRunOwner(ownership: ForegroundRecordingOwnership()) { _ in }
        let runID = try XCTUnwrap(owner.claim(binding: nil))
        let session = ForegroundTestSession()
        try owner.adoptStarting(session, run: runID)
        owner.noteStarted(session)
        try owner.activate(runID)
        XCTAssertTrue(owner.beginStopping())
        let stopping = try XCTUnwrap(owner.takeForStop())

        guard case .cancelled(let settling) = owner.cancel() else { return XCTFail("Capture was running") }
        XCTAssertNil(settling, "The draining session settles through its own stop")
        XCTAssertEqual(session.cancellations, 1)
        XCTAssertFalse(owner.stillOwnsStop(of: stopping), "A cancelled drain publishes nothing")
        XCTAssertFalse(owner.accepts(runID, session: stopping))
        XCTAssertNotNil(owner.ownedRunID, "The claim is held until the drain returns")
    }

    // MARK: Route

    func testRoute_offlineRemoteRunFallsBackOnDeviceAndRemembersTheIntendedModel() throws {
        var asked = 0
        var checked: [String] = []
        let route = try ForegroundCaptureRoute.resolve(
            requestedModelID: "deepgram/nova-3-streaming", usesBatch: false, connectivity: .unavailable,
            localCapability: { asked += 1; return .available }, requireAvailable: { checked.append($0) }
        )
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(route.modelID, AppleLocalModels.legacySpeechModelID)
        XCTAssertEqual(checked, [AppleLocalModels.legacySpeechModelID], "The offline model is what must run")
        XCTAssertEqual(route.offlineIntendedModelID, "deepgram/nova-3-streaming")
        XCTAssertEqual(route.notice, OfflineCaptureRouting.fallbackNotice)
        XCTAssertTrue(route.requiresStrictOnDeviceRecognition)

        XCTAssertThrowsError(try ForegroundCaptureRoute.resolve(
            requestedModelID: "deepgram/nova-3-streaming", usesBatch: false, connectivity: .unavailable,
            localCapability: { .unavailable }, requireAvailable: { _ in }
        )) {
            guard case .offlineLocalRecognitionUnavailable? = $0 as? iOSTranscriptionError else {
                return XCTFail("\($0)")
            }
        }
    }

    func testRoute_onlineAndBatchRunsKeepTheirModelWithoutAskingForLocalCapability() throws {
        var checked: [String] = []
        let online = try ForegroundCaptureRoute.resolve(
            requestedModelID: "deepgram/nova-3-streaming", usesBatch: false, connectivity: .available,
            localCapability: { XCTFail("Not needed online"); return .unknown }, requireAvailable: { checked.append($0) }
        )
        XCTAssertEqual(online.modelID, "deepgram/nova-3-streaming")
        XCTAssertNil(online.offlineIntendedModelID)
        let batch = try ForegroundCaptureRoute.resolve(
            requestedModelID: "deepgram/nova-3", usesBatch: true, connectivity: .unavailable,
            localCapability: { XCTFail("Batch never falls back"); return .unknown },
            requireAvailable: { checked.append($0) }
        )
        XCTAssertEqual(batch.modelID, "deepgram/nova-3")
        XCTAssertFalse(batch.requiresStrictOnDeviceRecognition)
        XCTAssertEqual(checked, ["deepgram/nova-3-streaming", "deepgram/nova-3"])
    }

    /// Issue #661: a keyless cloud model is reported, never swapped for Apple speech.
    func testRoute_unavailableModelRefusesTheRunInsteadOfSubstituting() {
        let unavailable = TranscriptionModelUnavailableError(
            modelIdentifier: "azure/mai-transcribe-2-streaming",
            modelName: "MAI-Transcribe-2",
            availability: TranscriptionModelAvailability(status: .missingCredential, providerName: "Azure Speech")
        )
        XCTAssertThrowsError(try ForegroundCaptureRoute.resolve(
            requestedModelID: "azure/mai-transcribe-2-streaming", usesBatch: false, connectivity: .available,
            localCapability: { .unknown }, requireAvailable: { _ in throw unavailable }
        )) {
            XCTAssertEqual($0 as? TranscriptionModelUnavailableError, unavailable)
        }
    }

    // MARK: Stop settlement

    /// The provider's result wins; the shown interim text is used only when the
    /// result is blank (a very short recording), as before the split.
    func testSettle_resultWinsAndShownTextFillsOnlyABlankResult() async {
        for (drained, expected) in [("final words", "final words"), ("  ", "the shown words")] {
            let session = ForegroundTestSession()
            session.stopOperation = { ForegroundTestSession.result(drained) }
            let outcome = await ForegroundCaptureFinalisation.settle(
                session, handsFree: false, stillOwned: { true },
                shown: { ForegroundTestSession.result("the shown words") },
                onFailure: { _ in XCTFail("The drain succeeded"); return false }
            )
            guard case .finished(let result) = outcome else { return XCTFail("Expected a finished stop") }
            XCTAssertEqual(result.text, expected)
        }
    }

    func testSettle_failedDrainKeepsShownTextOnlyWhenTheOwnerSaysSo() async {
        for keeps in [true, false] {
            let session = ForegroundTestSession()
            session.stopOperation = { throw iOSTranscriptionError.interrupted }
            var reported: [Error] = []
            let outcome = await ForegroundCaptureFinalisation.settle(
                session, handsFree: false, stillOwned: { true },
                shown: { ForegroundTestSession.result("kept words") },
                onFailure: { reported.append($0); return keeps }
            )
            XCTAssertEqual(session.cancellations, 1, "A failed drain cancels capture")
            XCTAssertEqual(reported.count, 1)
            switch outcome {
            case .finished(let result): XCTAssertTrue(keeps); XCTAssertEqual(result.text, "kept words")
            case .abandoned: XCTAssertFalse(keeps)
            case .discarded: XCTFail("Still owned")
            }
        }
    }

    func testSettle_cancelDuringTheDrainDiscardsAndNeverReportsFailure() async {
        let session = ForegroundTestSession()
        session.stopOperation = { throw CancellationError() }
        let failed = await ForegroundCaptureFinalisation.settle(
            session, handsFree: false, stillOwned: { false },
            shown: { ForegroundTestSession.result("words") },
            onFailure: { _ in XCTFail("A retired stop reports nothing"); return true }
        )
        guard case .abandoned = failed else { return XCTFail("A retired failed stop is abandoned") }

        session.stopOperation = { ForegroundTestSession.result("words") }
        let drained = await ForegroundCaptureFinalisation.settle(
            session, handsFree: false, stillOwned: { false },
            shown: { ForegroundTestSession.result("") }, onFailure: { _ in true }
        )
        guard case .discarded(let result) = drained else { return XCTFail("Cancel discards the utterance") }
        XCTAssertEqual(result.text, "words")
    }

    // MARK: Shown transcript

    func testShownTranscript_partialsKeepTheThrottledCountAndTheFinalIsExact() {
        var shown = ForegroundShownTranscript()
        shown.show(partial: "one two", words: 2)
        shown.show(partial: "one two three", words: nil)
        XCTAssertEqual(shown.text, "one two three")
        XCTAssertEqual(shown.wordCount, 2, "a partial the mirror did not admit keeps the earlier count")

        shown.confidence = 0.8
        shown.show(final: "one two\nthree  four")
        XCTAssertEqual(shown.wordCount, 4)
        let result = shown.result(confidence: shown.confidence, duration: 3, model: "apple/local")
        XCTAssertEqual(result.text, "one two\nthree  four")
        XCTAssertEqual(result.confidence, 0.8)
        XCTAssertEqual(result.duration, 3)
        XCTAssertEqual(result.modelIdentifier, "apple/local")
    }
}
#endif
