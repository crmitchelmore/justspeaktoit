#if IOS_KEYBOARD_FEATURE
import Foundation
import SpeakCore
import XCTest

@MainActor
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

        init(before: String, after: String = "") {
            self.before = before
            self.after = after
        }

        var text: String { before + after }

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

    private static let documentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let availableCapabilities = KeyboardViewModel.DirectCaptureCapabilities(
        microphonePermission: .granted,
        speechRecognitionPermission: .granted,
        speechRecognizerAvailable: { _ in true }
    )

    private func makeModel(
        engine: FakeEngine,
        policy: KeyboardCapturePlanner.DirectCapturePolicy = .enabled,
        capabilities: @escaping () -> KeyboardViewModel.DirectCaptureCapabilities = {
            Self.availableCapabilities
        }
    ) -> KeyboardViewModel {
        let suiteName = "KeyboardViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let handoffStore = KeyboardHandoffStore(defaults: defaults)
        let instantStore = KeyboardInstantDictationStore(defaults: defaults)
        let preferences = KeyboardDictationPreferencesStore(defaults: defaults)
        return KeyboardViewModel(
            engine: engine,
            handoff: KeyboardHandoffController(store: handoffStore, instantSessionStore: instantStore),
            handoffStore: handoffStore,
            preferences: preferences,
            directCapturePolicy: policy,
            directCaptureCapabilities: capabilities
        )
    }

    private func activate(_ model: KeyboardViewModel, document: DocumentProxy) {
        model.activate(
            hasFullAccess: true,
            documentIdentifier: Self.documentID,
            insertText: document.insertText,
            deleteBackward: document.deleteBackward,
            contextBeforeInput: { document.before },
            contextAfterInput: { document.after }
        )
    }
}
#endif
