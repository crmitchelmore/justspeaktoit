import Combine
import Foundation
import SpeakCore

/// Top-level keyboard model. Plans the capture path for each appearance and
/// drives either the in-extension dictation engine (primary) or the Instant
/// Dictation handoff (fallback), exposing one surface to the SwiftUI view.
@MainActor
final class KeyboardViewModel: ObservableObject {
    enum Mode: Equatable {
        case direct
        case handoff
        case blocked(KeyboardLaunchPolicy.BlockReason)
    }

    @Published private(set) var mode: Mode = .blocked(.fullAccessRequired)
    @Published private(set) var directState: KeyboardDictationMachine.State = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var languageChipLabel: String?

    let handoff: KeyboardHandoffController

    private var machine = KeyboardDictationMachine()
    private let engine: KeyboardDictationEngine
    private let handoffStore: KeyboardHandoffStore
    private let preferences: KeyboardDictationPreferencesStore
    private var languageSelection = KeyboardLanguageSelection.automaticOnly
    private var handoffForwarder: AnyCancellable?

    private var currentDocumentIdentifier: UUID?
    private var proxyInsert: ((String) -> Void)?
    private var proxyDeleteBackward: (() -> Void)?
    private var contextBeforeInput: (() -> String?)?

    init() {
        self.engine = KeyboardDictationEngine()
        self.handoff = KeyboardHandoffController()
        self.handoffStore = .shared
        self.preferences = .shared
        engine.onEvent = { [weak self] event in
            self?.dispatch(event)
        }
        // Republish nested handoff changes so the shared root view refreshes.
        handoffForwarder = handoff.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isCapturing: Bool {
        machine.isCapturing
    }

    // MARK: - Lifecycle from the input view controller

    func activate(
        hasFullAccess: Bool,
        documentIdentifier: UUID,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        contextBeforeInput: @escaping () -> String?
    ) {
        self.currentDocumentIdentifier = documentIdentifier
        self.proxyInsert = insertText
        self.proxyDeleteBackward = deleteBackward
        self.contextBeforeInput = contextBeforeInput
        handoffStore.recordExtensionObservation(hasFullAccess: hasFullAccess)

        languageSelection = preferences.selection()
        refreshLanguageChip()

        let path = KeyboardCapturePlanner.path(
            hasFullAccess: hasFullAccess,
            sharedContainerAvailable: handoffStore.isAvailable,
            microphonePermission: KeyboardDictationEngine.microphonePermission(),
            speechRecognitionPermission: KeyboardDictationEngine.speechRecognitionPermission(),
            speechRecognizerAvailable: KeyboardDictationEngine.recognizerAvailable(
                localeIdentifier: activeLocaleIdentifier
            )
        )
        switch path {
        case .direct:
            mode = .direct
            machine = KeyboardDictationMachine()
            directState = machine.state
            liveText = ""
        case .handoff:
            enterHandoffMode()
        case let .blocked(reason):
            mode = .blocked(reason)
        }
    }

    func deactivate() {
        dispatch(.dismissed)
        handoff.deactivate()
        proxyInsert = nil
        proxyDeleteBackward = nil
        contextBeforeInput = nil
    }

    func updateDocumentContext(documentIdentifier: UUID, selectionChanged: Bool) {
        let changedDocument = currentDocumentIdentifier != documentIdentifier
        currentDocumentIdentifier = documentIdentifier
        switch mode {
        case .direct:
            // The keyboard's own streamed insertions raise text/selection
            // callbacks, so only a genuine document change ends the session.
            if changedDocument, machine.isCapturing {
                dispatch(.targetChanged)
            }
        case .handoff:
            handoff.updateDocumentContext(
                documentIdentifier: documentIdentifier,
                selectionChanged: selectionChanged
            )
        case .blocked:
            break
        }
    }

    // MARK: - User intents

    func micTapped() {
        switch mode {
        case .direct:
            dispatch(.micTapped)
        case .handoff:
            switch handoff.presentation {
            case .recording:
                handoff.finish()
            case .idle, .inserted, .cancelled:
                handoff.start()
            case .unavailable, .targetChanged, .error:
                handoff.retry()
            case .starting, .transcribing, .waitingForApp:
                break
            }
        case .blocked:
            break
        }
    }

    func cancelTapped() {
        switch mode {
        case .direct:
            dispatch(.dismissed)
        case .handoff:
            handoff.cancel()
        case .blocked:
            break
        }
    }

    func cycleLanguage() {
        guard mode == .direct, !machine.isCapturing,
              let next = languageSelection.nextQuickIdentifier else {
            return
        }
        languageSelection = preferences.select(next)
        refreshLanguageChip()
    }

    // MARK: - Direct capture wiring

    private var activeLocaleIdentifier: String {
        TranscriptionLanguageCatalog.localeIdentifier(
            for: languageSelection.selectedIdentifier
        )
    }

    private func dispatch(_ event: KeyboardDictationMachine.Event) {
        let effects = machine.handle(event)
        directState = machine.state
        liveText = machine.liveText
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: KeyboardDictationMachine.Effect) {
        switch effect {
        case .startCapture:
            insertLeadingSeparatorIfNeeded()
            engine.start(localeIdentifier: activeLocaleIdentifier)
        case .stopCapture:
            engine.stop()
        case .cancelCapture:
            engine.cancel()
            fallBackToHandoffIfDirectCaptureIsImpossible()
        case let .applyEdit(edit):
            apply(edit)
        }
    }

    private func apply(_ edit: KeyboardTranscriptEdit) {
        guard let proxyInsert, let proxyDeleteBackward else { return }
        for _ in 0..<edit.deleteCount {
            deleteOneUserPerceivedCharacter(using: proxyDeleteBackward)
        }
        if !edit.insertion.isEmpty {
            proxyInsert(edit.insertion)
        }
    }

    /// `KeyboardTranscriptEdit.deleteCount` counts user-perceived characters,
    /// but `UITextDocumentProxy.deleteBackward()` can remove a single Unicode
    /// scalar of a composed cluster (an emoji ZWJ sequence, for example),
    /// leaving a fragment behind. Extra deletes are issued only while the
    /// document context confirms the tail is still a shrinking fragment of the
    /// cluster we set out to remove, so this can never eat host text.
    private func deleteOneUserPerceivedCharacter(using deleteBackward: () -> Void) {
        guard let cluster = contextBeforeInput?()?.last, cluster.unicodeScalars.count > 1 else {
            deleteBackward()
            return
        }
        var remainingScalars = cluster.unicodeScalars.count
        while remainingScalars > 0 {
            deleteBackward()
            remainingScalars -= 1
            guard remainingScalars > 0,
                  let tail = contextBeforeInput?()?.last,
                  tail.unicodeScalars.count == remainingScalars,
                  String(cluster).unicodeScalars.starts(with: tail.unicodeScalars) else {
                return
            }
        }
    }

    private func insertLeadingSeparatorIfNeeded() {
        guard let separator = KeyboardTranscriptStreamer.leadingSeparator(
            contextBeforeInput: contextBeforeInput?()
        ) else {
            return
        }
        proxyInsert?(separator)
    }

    /// After a permission-style failure the direct path cannot recover inside
    /// this appearance, so the keyboard degrades to the app-owned handoff.
    private func fallBackToHandoffIfDirectCaptureIsImpossible() {
        guard mode == .direct,
              case let .failed(failure) = machine.state,
              failure == .microphoneUnavailable || failure == .speechRecognitionUnavailable else {
            return
        }
        enterHandoffMode()
    }

    private func enterHandoffMode() {
        mode = .handoff
        guard let currentDocumentIdentifier, let proxyInsert else { return }
        handoff.activate(
            documentIdentifier: currentDocumentIdentifier,
            insertText: proxyInsert
        )
    }

    private func refreshLanguageChip() {
        languageChipLabel = languageSelection.quickIdentifiers.count > 1
            ? KeyboardLanguageSelection.chipLabel(for: languageSelection.selectedIdentifier)
            : nil
    }
}
