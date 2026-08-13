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
    @Published private(set) var profileChipLabel: String?

    let handoff: KeyboardHandoffController

    private var machine = KeyboardDictationMachine()
    private let engine: KeyboardDictationEngine
    private let handoffStore: KeyboardHandoffStore
    private let preferences: KeyboardDictationPreferencesStore
    private var languageSelection = KeyboardLanguageSelection.automaticOnly
    private var profileSelection = KeyboardProfileSelection.verbatim
    private var handoffForwarder: AnyCancellable?
    private var polishTask: Task<Void, Never>?

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

    /// Capture or profile post-processing is in flight; the quick-switch chips
    /// and the editing keys stay disabled until it settles.
    var isBusy: Bool {
        machine.isBusy
    }

    /// Full name of the selected dictation profile, for accessibility.
    var profileDisplayName: String {
        profileSelection.displayName
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
        profileSelection = preferences.profileSelection()
        refreshChips()

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
        cancelPolish()
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
            guard changedDocument else { return }
            if machine.isCapturing {
                dispatch(.targetChanged)
            }
            // A pending rewrite belongs to the field that was dictated into.
            cancelPolish()
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
            // Bailing out of a pending rewrite keeps the raw transcript.
            cancelPolish()
            dispatch(.dismissed)
        case .handoff:
            handoff.cancel()
        case .blocked:
            break
        }
    }

    func cycleLanguage() {
        guard mode == .direct, !machine.isBusy,
              let next = languageSelection.nextQuickIdentifier else {
            return
        }
        languageSelection = preferences.select(next)
        refreshChips()
    }

    func cycleProfile() {
        guard mode == .direct, !machine.isBusy,
              let next = profileSelection.nextQuickIdentifier else {
            return
        }
        profileSelection = preferences.selectProfile(next)
        refreshChips()
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
        startPolishIfNeeded(after: event)
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
    /// leaving a fragment behind. Extra deletes are issued only while the whole
    /// visible document context matches exactly what a partial, scalar-by-scalar
    /// deletion would leave; any other outcome — including a host that removed
    /// the cluster whole, or a truncated context window — stops immediately, so
    /// this can never eat host text.
    private func deleteOneUserPerceivedCharacter(using deleteBackward: () -> Void) {
        guard let contextBefore = contextBeforeInput?(),
              let cluster = contextBefore.last,
              cluster.unicodeScalars.count > 1 else {
            deleteBackward()
            return
        }
        let scalarsInCluster = cluster.unicodeScalars.count
        var removedScalars = 0
        while removedScalars < scalarsInCluster {
            deleteBackward()
            removedScalars += 1
            guard removedScalars < scalarsInCluster,
                  let context = contextBeforeInput?(),
                  context.unicodeScalars.elementsEqual(
                      contextBefore.unicodeScalars.dropLast(removedScalars)
                  ) else {
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

    // MARK: - Dictation profile post-processing

    /// Characters of the dictated text that must still sit immediately before
    /// the cursor for a rewrite to be applied.
    private static let polishAnchorLength = 24

    /// Runs the selected profile's cleanup on the finished transcript, entirely
    /// on device. The extension holds no API keys and makes no network request
    /// for this, so when Apple's on-device model is unavailable the profile
    /// selection still persists and mirrors while the raw transcript stands.
    private func startPolishIfNeeded(after event: KeyboardDictationMachine.Event) {
        guard case .finalized = event, mode == .direct, directState == .finished,
              let prompt = profileSelection.systemPrompt(),
              AppleFoundationModelPolisher.isAvailable else {
            return
        }
        let dictated = machine.liveText
        guard !dictated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        dispatch(.polishStarted)
        polishTask = Task { [weak self] in
            let polished = try? await AppleFoundationModelPolisher.process(
                text: dictated,
                systemPrompt: prompt
            )
            guard !Task.isCancelled else { return }
            self?.finishPolish(with: polished, replacing: dictated)
        }
    }

    private func finishPolish(with polished: String?, replacing dictated: String) {
        polishTask = nil
        guard machine.isPolishing else { return }
        guard let polished,
              !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cursorStillFollows(dictated) else {
            dispatch(.polishFailed)
            return
        }
        dispatch(.polished(polished))
    }

    /// The user can move the caret while the on-device model runs. A rewrite is
    /// only applied while the visible context still ends with what this session
    /// dictated, so the delete-and-reinsert can never reach host text.
    private func cursorStillFollows(_ dictated: String) -> Bool {
        guard let context = contextBeforeInput?() else { return false }
        let anchor = String(dictated.suffix(Self.polishAnchorLength))
        return !anchor.isEmpty && context.hasSuffix(anchor)
    }

    private func cancelPolish() {
        polishTask?.cancel()
        polishTask = nil
        if machine.isPolishing {
            dispatch(.polishFailed)
        }
    }

    private func refreshChips() {
        languageChipLabel = languageSelection.quickIdentifiers.count > 1
            ? KeyboardLanguageSelection.chipLabel(for: languageSelection.selectedIdentifier)
            : nil
        // A profile chip that cannot change the transcript would be a dead key,
        // so it appears only where the on-device cleanup engine can run.
        profileChipLabel = profileSelection.quickIdentifiers.count > 1
            && AppleFoundationModelPolisher.isAvailable
            ? profileSelection.chipLabel
            : nil
    }
}
