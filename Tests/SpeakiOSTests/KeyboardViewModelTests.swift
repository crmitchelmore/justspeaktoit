#if IOS_KEYBOARD_FEATURE
import Foundation
import SpeakCore
import XCTest

// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
final class KeyboardViewModelTests: XCTestCase {
    private final class FakeEngine: KeyboardDictationEngineProtocol {
        var onEvent: ((UUID, KeyboardDictationMachine.Event) -> Void)?
        private(set) var startedRunIDs: [UUID] = []
        private(set) var stoppedRunIDs: [UUID] = []
        private(set) var cancelledRunIDs: [UUID] = []

        func start(runID: UUID, localeIdentifier _: String) {
            startedRunIDs.append(runID)
        }

        func stop(runID: UUID) {
            stoppedRunIDs.append(runID)
        }

        func cancel(runID: UUID) {
            cancelledRunIDs.append(runID)
        }

        func emit(_ event: KeyboardDictationMachine.Event, for runID: UUID) {
            onEvent?(runID, event)
        }
    }

    private final class DocumentProxy {
        var before: String
        var after: String
        var deletesScalars = false
        var contextLimit: Int?

        init(before: String, after: String = "") {
            self.before = before
            self.after = after
        }

        var text: String { before + after }

        var contextBeforeInput: String {
            guard let contextLimit else { return before }
            return String(before.suffix(contextLimit))
        }

        func insertText(_ text: String) {
            before += text
        }

        func deleteBackward() {
            guard !before.isEmpty else { return }
            if deletesScalars {
                var scalars = before.unicodeScalars
                scalars.removeLast()
                before = String(scalars)
            } else {
                before.removeLast()
            }
        }

        func moveCursor(characterOffset: Int) {
            let text = self.text
            let index = text.index(text.startIndex, offsetBy: characterOffset)
            before = String(text[..<index])
            after = String(text[index...])
        }
    }

    private struct Harness {
        let model: KeyboardViewModel
        let handoffStore: KeyboardHandoffStore
        let instantStore: KeyboardInstantDictationStore
        let preferences: KeyboardDictationPreferencesStore
    }

    func testDisabledDirectCapture_plansHandoffWithoutReadingPermissions() {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        var capabilityReads = 0
        let model = makeModel(
            engine: engine,
            policy: .disabled,
            capabilities: {
                capabilityReads += 1
                return Self.availableCapabilities
            }
        )

        activate(model, document: document)

        XCTAssertEqual(model.mode, .handoff)
        XCTAssertEqual(capabilityReads, 0)
        XCTAssertTrue(engine.startedRunIDs.isEmpty)
        model.deactivate()
    }

    func testDisabledDirectCapture_localProfileHandsOffExactSnapshotWithoutCapabilityReads() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        var capabilityReads = 0
        let harness = makeHarness(
            engine: engine,
            policy: .disabled,
            capabilities: {
                capabilityReads += 1
                return Self.availableCapabilities
            },
            configurePreferences: { preferences in
                Self.publishProfileCatalogue(preferences)
                preferences.selectProfile(KeyboardDictationProfileCatalog.directIdentifier)
            },
            instantReady: true
        )
        let expectedProfile = harness.preferences.profileSelection().selectedProfile

        activate(harness.model, document: document)

        XCTAssertEqual(harness.model.mode, .handoff)
        XCTAssertEqual(capabilityReads, 0)
        XCTAssertEqual(try XCTUnwrap(harness.handoffStore.activeRecord()).profile, expectedProfile)
        XCTAssertTrue(engine.startedRunIDs.isEmpty)
        harness.model.deactivate()
    }

    func testAppProfile_handsOffExactSnapshotRegardlessOfDirectCapturePolicy() throws {
        for policy: KeyboardCapturePlanner.DirectCapturePolicy in [.disabled, .enabled] {
            let engine = FakeEngine()
            let document = DocumentProxy(before: "Host")
            var capabilityReads = 0
            let harness = makeHarness(
                engine: engine,
                policy: policy,
                capabilities: {
                    capabilityReads += 1
                    return Self.availableCapabilities
                },
                configurePreferences: Self.publishProfileCatalogue,
                instantReady: true
            )
            let expectedProfile = harness.preferences.profileSelection().selectedProfile

            activate(harness.model, document: document)

            XCTAssertEqual(harness.model.mode, .handoff)
            XCTAssertEqual(capabilityReads, 0)
            XCTAssertEqual(try XCTUnwrap(harness.handoffStore.activeRecord()).profile, expectedProfile)
            XCTAssertTrue(engine.startedRunIDs.isEmpty)
            harness.model.deactivate()
        }
    }

    func testEnabledDirectCapture_localProfileUsesRunScopedDocumentSession() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host", after: " tail")
        let harness = makeHarness(
            engine: engine,
            configurePreferences: { preferences in
                Self.publishProfileCatalogue(preferences)
                preferences.selectProfile(KeyboardDictationProfileCatalog.directIdentifier)
            }
        )

        activate(harness.model, document: document)
        harness.model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis("dictated words"), for: runID)

        XCTAssertEqual(harness.model.mode, .direct)
        XCTAssertEqual(document.text, "Host dictated words tail")
        XCTAssertNil(harness.handoffStore.activeRecord())
        harness.model.deactivate()
    }

    func testIdleProfileAndLanguageSwitch_reconfiguresHandoffWithoutAutoStart() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        var capabilityReads = 0
        let harness = makeHarness(
            engine: engine,
            policy: .disabled,
            capabilities: {
                capabilityReads += 1
                return Self.availableCapabilities
            },
            configurePreferences: Self.publishProfileCatalogue
        )

        activate(harness.model, document: document)
        harness.model.selectProfile(KeyboardDictationProfileCatalog.directIdentifier)
        _ = harness.instantStore.start(enabling: true)
        harness.model.cycleLanguage()

        XCTAssertEqual(harness.model.mode, .handoff)
        XCTAssertTrue(harness.model.showsLanguageChip)
        XCTAssertEqual(harness.model.languageChipLabel, "EN-GB")
        XCTAssertEqual(harness.model.handoff.presentation, .idle)
        XCTAssertNil(harness.handoffStore.activeRecord())
        XCTAssertEqual(capabilityReads, 0)

        harness.model.micTapped()
        let request = try XCTUnwrap(harness.handoffStore.activeRecord())
        XCTAssertEqual(request.profile?.id, KeyboardDictationProfileCatalog.directIdentifier)
        XCTAssertEqual(request.profile?.languageIdentifier, "en-GB")
        harness.model.deactivate()
    }

    func testDelayedCallbacks_fromPreviousRunCannotReachNewRun() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        let model = makeModel(engine: engine)
        activate(model, document: document)

        model.micTapped()
        let runA = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runA)
        engine.emit(.hypothesis("first"), for: runA)
        model.cancelTapped()

        model.micTapped()
        let runB = try XCTUnwrap(engine.startedRunIDs.last)
        XCTAssertNotEqual(runA, runB)
        let beforeDelayedCallbacks = document.text

        engine.emit(.hypothesis("stale revision"), for: runA)
        engine.emit(.finalized("stale final"), for: runA)
        engine.emit(.captureFailed(.audioInterrupted), for: runA)

        XCTAssertEqual(document.text, beforeDelayedCallbacks)
        XCTAssertEqual(model.directState, .starting)
        XCTAssertFalse(engine.cancelledRunIDs.contains(runB))

        engine.emit(.captureStarted, for: runB)
        engine.emit(.hypothesis("second"), for: runB)
        XCTAssertEqual(document.text, "Host first second")
    }

    func testSameFieldCaretMove_pausesBeforeRevisingUnrelatedText() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "prefix suffix")
        let model = makeModel(engine: engine)
        activate(model, document: document)
        model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis("alpha beta"), for: runID)

        document.moveCursor(characterOffset: 3)
        let textAtMutation = document.text
        model.updateDocumentContext(documentIdentifier: Self.documentID, selectionChanged: true)
        engine.emit(.hypothesis("revised words"), for: runID)

        XCTAssertEqual(model.directState, .finished)
        XCTAssertEqual(document.text, textAtMutation)
        XCTAssertTrue(engine.cancelledRunIDs.contains(runID))
    }

    func testSameFieldHostEdit_invalidatesReplacementAnchor() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        let model = makeModel(engine: engine)
        activate(model, document: document)
        model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis("alpha beta"), for: runID)

        document.after = " external text"
        let textAtMutation = document.text
        model.updateDocumentContext(documentIdentifier: Self.documentID, selectionChanged: false)
        engine.emit(.hypothesis("revised words"), for: runID)

        XCTAssertEqual(document.text, textAtMutation)
        XCTAssertTrue(engine.cancelledRunIDs.contains(runID))
    }

    func testEmptyOrFailedCapture_leavesHostFieldUnchanged() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        let model = makeModel(engine: engine)
        activate(model, document: document)

        model.micTapped()
        let failedRun = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureFailed(.microphoneUnavailable), for: failedRun)
        XCTAssertEqual(document.text, "Host")

        // Reactivate direct mode after the permission-style fallback to model a
        // fresh build/run whose capture starts but produces no speech.
        model.deactivate()
        activate(model, document: document)
        model.micTapped()
        let emptyRun = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: emptyRun)
        engine.emit(.finalized(""), for: emptyRun)

        XCTAssertEqual(document.text, "Host")
        XCTAssertEqual(model.directState, .failed(.noSpeech))
    }

    func testComposedTailRevision_preservesHostTextWithScalarDeletingProxy() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        document.deletesScalars = true
        let model = makeModel(engine: engine)
        activate(model, document: document)
        model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis("👨‍👩‍👧‍👦"), for: runID)
        engine.emit(.hypothesis("🎉"), for: runID)

        XCTAssertEqual(document.text, "Host 🎉")
        XCTAssertEqual(model.directState, .recording)
    }

    func testBoundedContext_tailRevisionAppliesWithoutLosingAnchor() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "0123456789")
        document.contextLimit = 5
        let model = makeModel(engine: engine)
        activate(model, document: document)
        model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis("alpha"), for: runID)

        engine.emit(.hypothesis("beta"), for: runID)

        XCTAssertEqual(document.text, "0123456789 beta")
        XCTAssertEqual(model.directState, .recording)
    }

    func testEditExceedingAuthoredText_isRejectedBeforeDeleting() {
        let document = DocumentProxy(before: "Host")
        let session = KeyboardDocumentSession(
            insertText: document.insertText,
            deleteBackward: document.deleteBackward,
            contextBeforeInput: { document.contextBeforeInput },
            contextAfterInput: { document.after }
        )
        session.begin()
        XCTAssertEqual(
            session.apply(KeyboardTranscriptEdit(deleteCount: 0, insertion: "dictated")),
            .applied
        )

        let result = session.apply(KeyboardTranscriptEdit(deleteCount: 9, insertion: "replacement"))

        XCTAssertEqual(result, .anchorLost)
        XCTAssertEqual(document.text, "Host dictated")
    }

    func testCanonicallyEquivalentHostMutation_doesNotProveReplacementAnchor() {
        let document = DocumentProxy(before: "Host é")
        let session = KeyboardDocumentSession(
            insertText: document.insertText,
            deleteBackward: document.deleteBackward,
            contextBeforeInput: { document.before },
            contextAfterInput: { document.after }
        )
        session.begin()
        document.before = "Host e\u{301}"

        let result = session.apply(KeyboardTranscriptEdit(deleteCount: 1, insertion: "x"))

        XCTAssertEqual(result, .anchorLost)
        XCTAssertEqual(
            document.before.unicodeScalars.map(\.value),
            "Host e\u{301}".unicodeScalars.map(\.value)
        )
    }

    func testWhitespaceOnlyHypothesis_leavesNoStraySpaceWhenAudioIsInterrupted() throws {
        let engine = FakeEngine()
        let document = DocumentProxy(before: "Host")
        let model = makeModel(engine: engine)
        activate(model, document: document)
        model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis(" "), for: runID)
        XCTAssertNotEqual(document.text, "Host", "The session must own a separator to remove")

        engine.emit(.interrupted, for: runID)

        XCTAssertEqual(document.text, "Host")
        XCTAssertEqual(model.directState, .failed(.audioInterrupted))
    }

    func testWhitespaceOnlyHypothesis_removalKeepsHostTextWhenTheAnchorIsLost() {
        let document = DocumentProxy(before: "Host")
        let session = KeyboardDocumentSession(
            insertText: document.insertText,
            deleteBackward: document.deleteBackward,
            contextBeforeInput: { document.contextBeforeInput },
            contextAfterInput: { document.after }
        )
        session.begin()
        XCTAssertEqual(
            session.apply(KeyboardTranscriptEdit(deleteCount: 0, insertion: " ")),
            .applied
        )
        document.after = " external text"

        XCTAssertEqual(session.removeSeparatorIfTranscriptIsEmpty(), .anchorLost)
        XCTAssertEqual(document.before, "Host  ")
    }

    func testFieldChange_neverRemovesSeparatorWhitespaceFromTheNewField() throws {
        let engine = FakeEngine()
        // The new field reports a context identical to the old one, the only
        // case where the ownership guards alone could not tell them apart.
        let document = DocumentProxy(before: "Host")
        let model = makeModel(engine: engine)
        activate(model, document: document)
        model.micTapped()
        let runID = try XCTUnwrap(engine.startedRunIDs.last)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis(" "), for: runID)
        let textAtFieldChange = document.text

        model.updateDocumentContext(documentIdentifier: Self.otherDocumentID, selectionChanged: false)

        XCTAssertEqual(document.text, textAtFieldChange)
        XCTAssertEqual(model.directState, .failed(.targetChanged))
    }

    private static let documentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let otherDocumentID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
    private static let availableCapabilities = KeyboardViewModel.DirectCaptureCapabilities(
        microphonePermission: .granted,
        speechRecognitionPermission: .granted,
        speechRecognizerAvailable: { _ in true }
    )

    private static func publishProfileCatalogue(_ preferences: KeyboardDictationPreferencesStore) {
        preferences.mirrorAppPreference(selectedIdentifier: "en-GB")
        preferences.mirrorAppPreference(selectedIdentifier: "fr-FR")
        preferences.publishAppProfileSelection(
            configuration: KeyboardAppProfileConfiguration(
                transcriptionMode: .batch,
                transcriptionModelIdentifier: "openai/gpt-transcribe",
                languageIdentifier: "fr-FR",
                postProcessingEnabled: true,
                postProcessingModelIdentifier: "openrouter/openai/gpt-5-mini"
            )
        )
    }

    private func makeModel(
        engine: FakeEngine,
        policy: KeyboardCapturePlanner.DirectCapturePolicy = .enabled,
        capabilities: (@MainActor () -> KeyboardViewModel.DirectCaptureCapabilities)? = nil
    ) -> KeyboardViewModel {
        makeHarness(engine: engine, policy: policy, capabilities: capabilities).model
    }

    private func makeHarness(
        engine: FakeEngine,
        policy: KeyboardCapturePlanner.DirectCapturePolicy = .enabled,
        capabilities: (@MainActor () -> KeyboardViewModel.DirectCaptureCapabilities)? = nil,
        configurePreferences: (KeyboardDictationPreferencesStore) -> Void = { _ in },
        instantReady: Bool = false
    ) -> Harness {
        let suiteName = "KeyboardViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let handoffStore = KeyboardHandoffStore(defaults: defaults)
        let instantStore = KeyboardInstantDictationStore(defaults: defaults)
        let preferences = KeyboardDictationPreferencesStore(defaults: defaults)
        configurePreferences(preferences)
        if instantReady {
            _ = instantStore.start(enabling: true)
        }
        let model = KeyboardViewModel(
            engine: engine,
            handoff: KeyboardHandoffController(store: handoffStore, instantSessionStore: instantStore),
            handoffStore: handoffStore,
            preferences: preferences,
            directCapturePolicy: policy,
            directCaptureCapabilities: capabilities ?? { Self.availableCapabilities }
        )
        return Harness(
            model: model,
            handoffStore: handoffStore,
            instantStore: instantStore,
            preferences: preferences
        )
    }

    private func activate(_ model: KeyboardViewModel, document: DocumentProxy) {
        model.activate(
            hasFullAccess: true,
            documentIdentifier: Self.documentID,
            insertText: document.insertText,
            deleteBackward: document.deleteBackward,
            contextBeforeInput: { document.contextBeforeInput },
            contextAfterInput: { document.after }
        )
    }
}
#endif
