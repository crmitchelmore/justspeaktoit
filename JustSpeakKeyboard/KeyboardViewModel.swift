import Combine
import Foundation
import SpeakCore

/// Top-level keyboard model. Routes the selected mode to the in-extension
/// Apple Speech engine or the app-owned Instant Dictation handoff, exposing one
/// surface to the SwiftUI view.
@MainActor
// swiftlint:disable:next type_body_length
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
    private var profileSelection = KeyboardProfileSelection.directOnly
    private var handoffForwarder: AnyCancellable?
    private var hasFullAccess = false

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

    /// Capture or app handoff is in flight; the quick-switch chips and editing
    /// keys stay disabled until it settles.
    var isBusy: Bool {
        switch mode {
        case .direct:
            return machine.isCapturing
        case .handoff:
            return handoff.presentation == .starting || handoff.presentation == .recording
                || handoff.presentation == .transcribing
        case .blocked:
            return false
        }
    }

    /// Full name of the selected dictation profile, for accessibility.
    var profileDisplayName: String {
        profileSelection.displayName
    }

    var profileRouteDisplayName: String {
        profileSelection.route.displayName
    }

    var profileOptions: [KeyboardDictationProfileOption] {
        profileSelection.availableProfiles
    }

    var selectedProfileIdentifier: String {
        profileSelection.selectedIdentifier
    }

    // MARK: - Lifecycle from the input view controller

    func activate(
        hasFullAccess: Bool,
        documentIdentifier: UUID,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        contextBeforeInput: @escaping () -> String?
    ) {
        self.hasFullAccess = hasFullAccess
        self.currentDocumentIdentifier = documentIdentifier
        self.proxyInsert = insertText
        self.proxyDeleteBackward = deleteBackward
        self.contextBeforeInput = contextBeforeInput
        handoffStore.recordExtensionObservation(hasFullAccess: hasFullAccess)

        languageSelection = preferences.selection()
        profileSelection = preferences.profileSelection()
        refreshChips()

        configureCaptureMode(autoStartHandoff: true)
    }

    private func configureCaptureMode(autoStartHandoff: Bool) {
        guard let currentDocumentIdentifier, let proxyInsert else { return }
        if let reason = KeyboardLaunchPolicy.blockReason(
            hasFullAccess: hasFullAccess,
            sharedContainerAvailable: handoffStore.isAvailable
        ) {
            handoff.deactivate()
            mode = .blocked(reason)
            return
        }

        if profileSelection.route == .appHandoff {
            enterHandoffMode(autoStart: autoStartHandoff)
            return
        }

        let path = KeyboardCapturePlanner.path(
            hasFullAccess: true,
            sharedContainerAvailable: true,
            microphonePermission: KeyboardDictationEngine.microphonePermission(),
            speechRecognitionPermission: KeyboardDictationEngine.speechRecognitionPermission(),
            speechRecognizerAvailable: KeyboardDictationEngine.recognizerAvailable(
                localeIdentifier: activeLocaleIdentifier
            )
        )
        switch path {
        case .direct:
            handoff.deactivate()
            mode = .direct
            machine = KeyboardDictationMachine()
            directState = machine.state
            liveText = ""
        case .handoff:
            handoff.activate(
                documentIdentifier: currentDocumentIdentifier,
                profile: captureProfile,
                autoStart: autoStartHandoff,
                insertText: proxyInsert
            )
            mode = .handoff
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
            guard changedDocument else { return }
            if machine.isCapturing {
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
        guard mode == .direct, !isBusy,
              let next = languageSelection.nextQuickIdentifier else {
            return
        }
        languageSelection = preferences.select(next)
        refreshChips()
    }

    func cycleProfile() {
        selectProfile(profileSelection.nextQuickIdentifier)
    }

    func selectProfile(_ identifier: String?) {
        guard !isBusy, identifier != nil else { return }
        profileSelection = preferences.selectProfile(identifier)
        refreshChips()
        configureCaptureMode(autoStartHandoff: false)
    }

    // MARK: - Direct capture wiring

    private var activeLocaleIdentifier: String {
        TranscriptionLanguageCatalog.localeIdentifier(
            for: captureProfile.languageIdentifier
        )
    }

    private var captureProfile: KeyboardDictationProfileOption {
        let selected = profileSelection.selectedProfile
        guard selected.route == .directAppleSpeech else { return selected }
        return KeyboardDictationProfileOption(
            id: selected.id,
            displayName: selected.displayName,
            chipLabel: selected.chipLabel,
            route: selected.route,
            transcriptionMode: selected.transcriptionMode,
            transcriptionModelIdentifier: selected.transcriptionModelIdentifier,
            languageIdentifier: languageSelection.selectedIdentifier,
            postProcessingEnabled: selected.postProcessingEnabled,
            postProcessingModelIdentifier: selected.postProcessingModelIdentifier
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
        enterHandoffMode(autoStart: true)
    }

    private func enterHandoffMode(autoStart: Bool) {
        mode = .handoff
        guard let currentDocumentIdentifier, let proxyInsert else { return }
        handoff.activate(
            documentIdentifier: currentDocumentIdentifier,
            profile: captureProfile,
            autoStart: autoStart,
            insertText: proxyInsert
        )
    }

    private func refreshChips() {
        languageChipLabel = languageSelection.quickIdentifiers.count > 1
            ? KeyboardLanguageSelection.chipLabel(for: languageSelection.selectedIdentifier)
            : nil
        profileChipLabel = profileSelection.availableProfiles.count > 1 ? profileSelection.chipLabel : nil
    }
}
