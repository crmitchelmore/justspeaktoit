import Combine
import Foundation
import SpeakCore

/// Top-level keyboard model. Plans the capture path for each appearance and
/// drives either the policy-gated in-extension engine or the Instant Dictation
/// handoff, exposing one surface to the SwiftUI view.
@MainActor
// swiftlint:disable:next type_body_length
final class KeyboardViewModel: ObservableObject {
    struct DirectCaptureCapabilities {
        let microphonePermission: KeyboardCapturePlanner.Permission
        let speechRecognitionPermission: KeyboardCapturePlanner.Permission
        let speechRecognizerAvailable: (String) -> Bool
    }

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
    private let engine: any KeyboardDictationEngineProtocol
    private let handoffStore: KeyboardHandoffStore
    private let preferences: KeyboardDictationPreferencesStore
    private let directCapturePolicy: KeyboardCapturePlanner.DirectCapturePolicy
    private let directCaptureCapabilities: () -> DirectCaptureCapabilities
    private var languageSelection = KeyboardLanguageSelection.automaticOnly
    private var profileSelection = KeyboardProfileSelection.directOnly
    private var handoffForwarder: AnyCancellable?
    private var hasFullAccess = false
    private var activeRunID: UUID?
    private var documentSession: KeyboardDocumentSession?

    private var currentDocumentIdentifier: UUID?
    private var proxyInsert: ((String) -> Void)?

    init(
        engine: any KeyboardDictationEngineProtocol = KeyboardDictationEngine(),
        handoff: KeyboardHandoffController = KeyboardHandoffController(),
        handoffStore: KeyboardHandoffStore = .shared,
        preferences: KeyboardDictationPreferencesStore = .shared,
        directCapturePolicy: KeyboardCapturePlanner.DirectCapturePolicy = KeyboardViewModel.buildDirectCapturePolicy,
        directCaptureCapabilities: @escaping () -> DirectCaptureCapabilities = {
            DirectCaptureCapabilities(
                microphonePermission: KeyboardDictationEngine.microphonePermission(),
                speechRecognitionPermission: KeyboardDictationEngine.speechRecognitionPermission(),
                speechRecognizerAvailable: {
                    KeyboardDictationEngine.recognizerAvailable(localeIdentifier: $0)
                }
            )
        }
    ) {
        self.engine = engine
        self.handoff = handoff
        self.handoffStore = handoffStore
        self.preferences = preferences
        self.directCapturePolicy = directCapturePolicy
        self.directCaptureCapabilities = directCaptureCapabilities
        engine.onEvent = { [weak self] runID, event in
            self?.receiveEngineEvent(runID: runID, event: event)
        }
        // Republish nested handoff changes so the shared root view refreshes.
        handoffForwarder = handoff.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private static var buildDirectCapturePolicy: KeyboardCapturePlanner.DirectCapturePolicy {
        #if IOS_KEYBOARD_DIRECT_CAPTURE
        .enabled
        #else
        .disabled
        #endif
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

    /// Language belongs to the selected Local profile, even when rollout
    /// policy routes that profile through the app-owned handoff.
    var showsLanguageChip: Bool {
        profileSelection.route == .directAppleSpeech
    }

    // MARK: - Lifecycle from the input view controller

    func activate(
        hasFullAccess: Bool,
        documentIdentifier: UUID,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        contextBeforeInput: @escaping () -> String?,
        contextAfterInput: @escaping () -> String?
    ) {
        self.hasFullAccess = hasFullAccess
        self.currentDocumentIdentifier = documentIdentifier
        self.proxyInsert = insertText
        self.documentSession = KeyboardDocumentSession(
            insertText: insertText,
            deleteBackward: deleteBackward,
            contextBeforeInput: contextBeforeInput,
            contextAfterInput: contextAfterInput
        )
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

        let path = plannedCapturePath(hasFullAccess: hasFullAccess)
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
        documentSession?.invalidate()
        documentSession = nil
    }

    func updateDocumentContext(documentIdentifier: UUID, selectionChanged: Bool) {
        let changedDocument = currentDocumentIdentifier != documentIdentifier
        currentDocumentIdentifier = documentIdentifier
        switch mode {
        case .direct:
            // Extension-authored edits update the session anchor before UIKit
            // callbacks arrive. Any other caret or host-text mutation makes
            // the bounded replacement region unprovable and pauses the run.
            if machine.isCapturing,
               changedDocument || documentSession?.anchorIsCurrent() != true {
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
        guard profileSelection.route == .directAppleSpeech, !isBusy,
              let next = languageSelection.nextQuickIdentifier else {
            return
        }
        languageSelection = preferences.select(next)
        refreshChips()
        configureCaptureMode(autoStartHandoff: false)
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
        if directState == .failed(.noSpeech) {
            _ = documentSession?.removeSeparatorIfTranscriptIsEmpty()
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
            engine.start(runID: runID, localeIdentifier: activeLocaleIdentifier)
        case .stopCapture:
            guard let activeRunID else { return }
            engine.stop(runID: activeRunID)
        case .cancelCapture:
            if let activeRunID {
                engine.cancel(runID: activeRunID)
                self.activeRunID = nil
            }
            fallBackToHandoffIfDirectCaptureIsImpossible()
        case let .applyEdit(edit):
            guard documentSession?.apply(edit) == .applied else {
                dispatch(.targetChanged)
                return
            }
        }
    }

    private func plannedCapturePath(hasFullAccess: Bool) -> KeyboardCapturePlanner.Path {
        guard directCapturePolicy == .enabled else {
            return KeyboardCapturePlanner.path(
                hasFullAccess: hasFullAccess,
                sharedContainerAvailable: handoffStore.isAvailable,
                directCapturePolicy: .disabled,
                microphonePermission: .denied,
                speechRecognitionPermission: .denied,
                speechRecognizerAvailable: false
            )
        }
        let capabilities = directCaptureCapabilities()
        return KeyboardCapturePlanner.path(
            hasFullAccess: hasFullAccess,
            sharedContainerAvailable: handoffStore.isAvailable,
            directCapturePolicy: .enabled,
            microphonePermission: capabilities.microphonePermission,
            speechRecognitionPermission: capabilities.speechRecognitionPermission,
            speechRecognizerAvailable: capabilities.speechRecognizerAvailable(activeLocaleIdentifier)
        )
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
