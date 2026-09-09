#if IOS_KEYBOARD_FEATURE
import Foundation
import SpeakCore
import XCTest

/// Exercise keyboard lifecycle callbacks against independent app/extension
/// store roles. App finalisation is driven explicitly to reproduce suspension
/// at each boundary without using a microphone or a provider.
@MainActor
final class KeyboardHandoffControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var app: KeyboardHandoffStore!
    private var keyboard: KeyboardHandoffStore!
    private var instant: KeyboardInstantDictationStore!
    private var controller: KeyboardHandoffController!
    private var inserted: [String] = []
    private let documentID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "KeyboardHandoffControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        app = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        keyboard = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
        instant = KeyboardInstantDictationStore(defaults: defaults)
        _ = instant.start(enabling: true)
        controller = makeController()
        inserted = []
    }

    override func tearDown() async throws {
        controller.deactivate()
        controller = nil
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testStopThenDismissBeforeAppHandlesFinish_preservesRequestAndInsertsOnceOnReturn() async throws {
        let requestID = try startRecording()
        controller.finish()
        controller.deactivate()

        XCTAssertEqual(app.record(matching: requestID)?.phase, .finishRequested)
        _ = try app.markTranscribing(requestID: requestID)
        _ = try app.complete(requestID: requestID, transcript: "finished after dismissal")
        // Allow an incorrectly retained poll task to attempt insertion.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(keyboard.record(matching: requestID)?.phase, .completed)

        activate()
        XCTAssertEqual(inserted, ["finished after dismissal"])
        XCTAssertEqual(controller.presentation, .inserted)
        XCTAssertNil(keyboard.activeRecord())
        activate()
        XCTAssertEqual(inserted.count, 1)
    }

    func testDismissDuringTranscribing_keepsFinishingUIOnReturnWithoutEarlyInsertion() async throws {
        let requestID = try startRecording()
        controller.finish()
        _ = try app.markTranscribing(requestID: requestID)
        controller.deactivate()
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(app.record(matching: requestID)?.phase, .transcribing)
        XCTAssertTrue(inserted.isEmpty)
        activate()
        XCTAssertEqual(controller.presentation, .transcribing)
        XCTAssertTrue(inserted.isEmpty)
        _ = try app.complete(requestID: requestID, transcript: "polished result")
        activate()
        XCTAssertEqual(inserted, ["polished result"])
    }

    func testDeactivate_releasesTheInactiveInsertionCallback() throws {
        let requestID = try startRecording()
        controller.finish()
        var callbackOwner: NSObject? = NSObject()
        weak var retainedOwner = callbackOwner
        activate(insert: { [owner = callbackOwner!] _ in _ = owner.description })
        callbackOwner = nil
        XCTAssertNotNil(retainedOwner)

        controller.deactivate()

        XCTAssertNil(retainedOwner)
        XCTAssertEqual(app.record(matching: requestID)?.phase, .finishRequested)
    }

    func testCompletedWhileInactive_recreatedControllerRecoversMatchingResult() throws {
        let requestID = try startRecording()
        controller.finish()
        controller.deactivate()
        controller = nil

        _ = try app.markTranscribing(requestID: requestID)
        _ = try app.complete(requestID: requestID, transcript: "recover me")
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(keyboard.record(matching: requestID)?.phase, .completed)
        controller = makeController()

        activate()
        XCTAssertEqual(inserted, ["recover me"])
        XCTAssertNil(app.activeRecord())
    }

    func testCompletedBeforeDismissal_retainedControllerRecoversMatchingResult() throws {
        let requestID = try startRecording()
        controller.finish()
        _ = try app.markTranscribing(requestID: requestID)
        _ = try app.complete(requestID: requestID, transcript: "already complete")
        controller.deactivate()

        activate()
        XCTAssertEqual(inserted, ["already complete"])
        XCTAssertNil(app.activeRecord())
    }

    func testSameDocumentCaretChanges_preserveEveryInFlightPhaseAndInsertAtCurrentCaret() throws {
        var before = "prefix suffix"
        var after = ""
        activate(insert: { before += $0 })
        controller.start()
        let requestID = try XCTUnwrap(keyboard.activeRecord()?.requestID)
        controller.updateDocumentContext(documentIdentifier: documentID, selectionChanged: true)
        XCTAssertEqual(app.record(matching: requestID)?.phase, .requested)
        _ = try app.markRecording(requestID: requestID)
        controller.updateDocumentContext(documentIdentifier: documentID, selectionChanged: true)
        XCTAssertEqual(app.record(matching: requestID)?.phase, .recording)
        controller.finish()
        controller.updateDocumentContext(documentIdentifier: documentID, selectionChanged: true)
        XCTAssertEqual(app.record(matching: requestID)?.phase, .finishRequested)
        _ = try app.markTranscribing(requestID: requestID)
        before = "prefix "
        after = " suffix"
        controller.updateDocumentContext(documentIdentifier: documentID, selectionChanged: true)
        XCTAssertEqual(app.record(matching: requestID)?.phase, .transcribing)
        _ = try app.complete(requestID: requestID, transcript: "dictated")

        activate(insert: { before += $0 })
        XCTAssertEqual(before + after, "prefix dictated suffix")
        XCTAssertNil(app.activeRecord())
    }

    func testDifferentDocumentWhileFinishing_cancelsWithoutDeliveringOldText() throws {
        let requestID = try startRecording()
        controller.finish()
        controller.updateDocumentContext(documentIdentifier: UUID(), selectionChanged: false)

        XCTAssertEqual(app.record(matching: requestID)?.phase, .cancelled)
        XCTAssertEqual(controller.presentation, .targetChanged)
        XCTAssertThrowsError(try app.markTranscribing(requestID: requestID))
        XCTAssertTrue(inserted.isEmpty)
    }

    func testReturnToDifferentDocumentWhileTranscribing_cancelsWithoutInsertion() throws {
        let requestID = try startRecording()
        controller.finish()
        controller.deactivate()
        _ = try app.markTranscribing(requestID: requestID)

        activate(document: UUID())
        XCTAssertEqual(app.record(matching: requestID)?.phase, .cancelled)
        XCTAssertEqual(controller.presentation, .targetChanged)
        XCTAssertTrue(inserted.isEmpty)
    }

    func testCompletedResult_differentDocumentCannotConsumeIt() throws {
        let requestID = try startRecording()
        controller.finish()
        controller.deactivate()
        _ = try app.markTranscribing(requestID: requestID)
        _ = try app.complete(requestID: requestID, transcript: "original field only")

        activate(document: UUID())
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(controller.presentation, .targetChanged)
        XCTAssertEqual(app.record(matching: requestID)?.phase, .completed)
        activate()
        XCTAssertEqual(inserted, ["original field only"])
    }

    func testExplicitCancellationAfterStop_stillPreventsDelivery() throws {
        let requestID = try startRecording()
        controller.finish()
        _ = try app.markTranscribing(requestID: requestID)
        controller.cancel()
        controller.deactivate()

        XCTAssertThrowsError(try app.complete(requestID: requestID, transcript: "cancelled"))
        activate()
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(controller.presentation, .cancelled)
    }

    func testSupersedingNonce_cannotBeConsumedByReturningOldController() throws {
        let oldID = try startRecording()
        controller.finish()
        controller.deactivate()
        keyboard.clear(requestID: oldID)
        let replacement = try keyboard.createRequest(targetDocumentIdentifier: documentID)
        _ = try app.markRecording(requestID: replacement.requestID)
        _ = try keyboard.requestFinish(requestID: replacement.requestID)
        _ = try app.markTranscribing(requestID: replacement.requestID)
        _ = try app.complete(requestID: replacement.requestID, transcript: "new session")

        activate()
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(app.activeRecord()?.requestID, replacement.requestID)
        XCTAssertThrowsError(try app.complete(requestID: oldID, transcript: "old session"))
    }

    func testDismissBeforeStop_cancelsRequestedAndRecordingPhases() throws {
        activate()
        controller.start()
        let requestedID = try XCTUnwrap(keyboard.activeRecord()?.requestID)
        controller.deactivate()
        XCTAssertEqual(app.record(matching: requestedID)?.phase, .cancelled)

        let recordingID = try startRecording()
        controller.deactivate()
        XCTAssertEqual(app.record(matching: recordingID)?.phase, .cancelled)
        XCTAssertTrue(inserted.isEmpty)
    }

    private func makeController() -> KeyboardHandoffController {
        KeyboardHandoffController(store: keyboard, instantSessionStore: instant)
    }

    private func activate(document: UUID? = nil, insert: ((String) -> Void)? = nil) {
        controller.activate(
            documentIdentifier: document ?? documentID,
            profile: KeyboardDictationProfileCatalog.selection(
                for: KeyboardAppProfileConfiguration(
                    transcriptionMode: .batch,
                    transcriptionModelIdentifier: "openai/gpt-transcribe",
                    languageIdentifier: "en-GB",
                    postProcessingEnabled: false,
                    postProcessingModelIdentifier: nil
                )
            ).selectedProfile,
            autoStart: false,
            insertText: insert ?? { [weak self] in self?.inserted.append($0) }
        )
    }

    private func startRecording() throws -> UUID {
        activate()
        controller.start()
        let requestID = try XCTUnwrap(keyboard.activeRecord()?.requestID)
        _ = try app.markRecording(requestID: requestID)
        return requestID
    }
}
#endif
