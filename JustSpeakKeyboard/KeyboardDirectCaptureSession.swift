import Foundation
import SpeakCore

/// The policy-gated in-extension capture path: one dictation machine, the
/// engine run it started and the document session its edits are applied to.
///
/// It owns the run identity, so a late event from a cancelled or finished
/// engine run is dropped here rather than reaching the machine.
@MainActor
final class KeyboardDirectCaptureSession {
    private var machine = KeyboardDictationMachine()
    private let engine: any KeyboardDictationEngineProtocol
    private var activeRunID: UUID?
    private var documentSession: KeyboardDocumentSession?

    /// Locale for the next capture, resolved from the selected profile when the
    /// run starts.
    var localeIdentifier: @MainActor () -> String = { "" }
    /// Called after every machine transition, before its effects run.
    var onStateChange: (@MainActor (KeyboardDictationMachine.State, String) -> Void)?
    /// Called after a capture is cancelled, once the machine has settled.
    var onCaptureCancelled: (@MainActor () -> Void)?

    init(engine: any KeyboardDictationEngineProtocol) {
        self.engine = engine
        engine.onEvent = { [weak self] runID, event in
            self?.receiveEngineEvent(runID: runID, event: event)
        }
    }

    var state: KeyboardDictationMachine.State {
        machine.state
    }

    var liveText: String {
        machine.liveText
    }

    var isCapturing: Bool {
        machine.isCapturing
    }

    /// Starts a fresh machine for a new direct-capture appearance.
    func reset() {
        machine = KeyboardDictationMachine()
        onStateChange?(machine.state, "")
    }

    func attach(_ session: KeyboardDocumentSession) {
        documentSession = session
    }

    /// Drops the document anchor so no later failure path edits a field this
    /// session never wrote to.
    func invalidateDocument() {
        documentSession?.invalidate()
    }

    func detachDocument() {
        documentSession?.invalidate()
        documentSession = nil
    }

    var documentAnchorIsCurrent: Bool {
        documentSession?.anchorIsCurrent() == true
    }

    func dispatch(_ event: KeyboardDictationMachine.Event) {
        let effects = machine.handle(event)
        onStateChange?(machine.state, machine.liveText)
        for effect in effects {
            perform(effect)
        }
        // Every failure that can follow a started capture must clean up the
        // session-owned separator. An interruption or a target change after a
        // whitespace-only hypothesis ends in `.failed`, and would otherwise
        // leave a stray space in the host document.
        switch machine.state {
        case .failed(.noSpeech), .failed(.audioInterrupted), .failed(.targetChanged):
            _ = documentSession?.removeSeparatorIfTranscriptIsEmpty()
        default:
            break
        }
    }

    private func receiveEngineEvent(runID: UUID, event: KeyboardDictationMachine.Event) {
        guard activeRunID == runID else { return }
        dispatch(event)
        switch event {
        case .captureFailed, .finalized:
            if activeRunID == runID {
                activeRunID = nil
            }
        default:
            break
        }
    }

    private func perform(_ effect: KeyboardDictationMachine.Effect) {
        switch effect {
        case .startCapture:
            documentSession?.begin()
            let runID = UUID()
            activeRunID = runID
            engine.start(runID: runID, localeIdentifier: localeIdentifier())
        case .stopCapture:
            guard let activeRunID else { return }
            engine.stop(runID: activeRunID)
        case .cancelCapture:
            if let activeRunID {
                engine.cancel(runID: activeRunID)
                self.activeRunID = nil
            }
            onCaptureCancelled?()
        case let .applyEdit(edit):
            guard documentSession?.apply(edit) == .applied else {
                dispatch(.targetChanged)
                return
            }
        }
    }
}
