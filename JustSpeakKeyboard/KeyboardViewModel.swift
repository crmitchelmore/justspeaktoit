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
    /// What the keyboard may do with a transcript the app has left pending
    /// (issues #1002, #1003). Recomputed on appearance, on every document
    /// change, and on each poll tick.
    @Published private(set) var pickupOffering: KeyboardPickupPolicy.Offering = .none

    let handoff: KeyboardHandoffController

    private var machine = KeyboardDictationMachine()
    private let engine: any KeyboardDictationEngineProtocol
    private let handoffStore: KeyboardHandoffStore
    private let preferences: KeyboardDictationPreferencesStore
    private let directCapturePolicy: KeyboardCapturePlanner.DirectCapturePolicy
    private let directCaptureCapabilities: @MainActor () -> DirectCaptureCapabilities
    private var languageSelection = KeyboardLanguageSelection.automaticOnly
    private var profileSelection = KeyboardProfileSelection.directOnly
    private var handoffForwarder: AnyCancellable?
    private var hasFullAccess = false
    private var activeRunID: UUID?
    private var documentSession: KeyboardDocumentSession?

    private var currentDocumentIdentifier: UUID?
    private var proxyInsert: ((String) -> Void)?
    private let deliveryStore: KeyboardDeliveryStore
    private var deliveryPreferences: KeyboardDeliveryPreferences = .default
    private var isSecureField = false
    private var activeInputModeCount = 0
    private var handBack: (() -> Void)?
    private var pickupTask: Task<Void, Never>?
    private var isDelivering = false

    /// Cadence for noticing an offer the app published while the keyboard was
    /// already on screen, and for refreshing the open-target advertisement.
    /// The store throttles the target rewrite, so this costs one small read
    /// per tick. Issue #990 separately owns pushing this over Darwin.
    private static let deliveryPollInterval = Duration.milliseconds(500)

    convenience init() {
        self.init(
            engine: KeyboardDictationEngine(),
            handoff: KeyboardHandoffController(),
            handoffStore: .shared,
            preferences: .shared,
            deliveryStore: .shared,
            directCapturePolicy: Self.buildDirectCapturePolicy,
            directCaptureCapabilities: {
                DirectCaptureCapabilities(
                    microphonePermission: KeyboardDictationEngine.microphonePermission(),
                    speechRecognitionPermission: KeyboardDictationEngine.speechRecognitionPermission(),
                    speechRecognizerAvailable: {
                        KeyboardDictationEngine.recognizerAvailable(localeIdentifier: $0)
                    }
                )
            }
        )
    }

    init(
        engine: any KeyboardDictationEngineProtocol,
        handoff: KeyboardHandoffController,
        handoffStore: KeyboardHandoffStore,
        preferences: KeyboardDictationPreferencesStore,
        deliveryStore: KeyboardDeliveryStore = .shared,
        directCapturePolicy: KeyboardCapturePlanner.DirectCapturePolicy,
        directCaptureCapabilities: @escaping @MainActor () -> DirectCaptureCapabilities
    ) {
        self.engine = engine
        self.handoff = handoff
        self.handoffStore = handoffStore
        self.preferences = preferences
        self.deliveryStore = deliveryStore
        self.directCapturePolicy = directCapturePolicy
        self.directCaptureCapabilities = directCaptureCapabilities
        engine.onEvent = { [weak self] runID, event in
            self?.receiveEngineEvent(runID: runID, event: event)
        }
        // Republish nested handoff changes so the shared root view refreshes.
        handoffForwarder = handoff.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        handoff.onDidInsert = { [weak self] in
            self?.handBackAfterInsertIfPermitted()
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

    // swiftlint:disable:next function_parameter_count
    func activate(
        hasFullAccess: Bool,
        documentIdentifier: UUID,
        // No default: "is this a password field?" is never a question the
        // caller may leave unanswered, and the safe answer to "unknown" is
        // `true` (see `KeyboardViewController.documentIsSecure`).
        isSecureField: Bool,
        activeInputModeCount: Int = 0,
        handBack: (() -> Void)? = nil,
        insertText: @escaping (String) -> Void,
        deleteBackward: @escaping () -> Void,
        contextBeforeInput: @escaping () -> String?,
        contextAfterInput: @escaping () -> String?
    ) {
        self.hasFullAccess = hasFullAccess
        self.currentDocumentIdentifier = documentIdentifier
        self.isSecureField = isSecureField
        self.activeInputModeCount = activeInputModeCount
        self.handBack = handBack
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
        deliveryPreferences = deliveryStore.preferences()
        refreshChips()

        configureCaptureMode(autoStartHandoff: true)
        refreshDelivery()
        startDeliveryLoop()
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
        pickupTask?.cancel()
        pickupTask = nil
        // Withdraw the open-target advertisement. Its short lifetime covers
        // the case where the extension is killed before this ever runs.
        deliveryStore.clearTarget()
        pickupOffering = .none
        proxyInsert = nil
        handBack = nil
        documentSession?.invalidate()
        documentSession = nil
    }

    /// Every host callback carries the *current* secure-entry answer, not the
    /// one that was true when the keyboard appeared. A field can turn into a
    /// password field — or focus can move to one — without the keyboard being
    /// dismissed, and the whole delivery surface has to follow that.
    func updateDocumentContext(
        documentIdentifier: UUID,
        selectionChanged: Bool,
        isSecureField: Bool
    ) {
        let changedDocument = currentDocumentIdentifier != documentIdentifier
        let becameSecure = isSecureField && !self.isSecureField
        currentDocumentIdentifier = documentIdentifier
        self.isSecureField = isSecureField
        if becameSecure {
            // Nothing may keep aiming at a field that is now collecting a
            // secret: withdraw the advertisement, drop the chip, and abandon
            // any capture that was going to write into it.
            deliveryStore.clearTarget()
            pickupOffering = .none
            switch mode {
            case .direct:
                if machine.isCapturing { dispatch(.targetChanged) }
            case .handoff:
                if handoff.isInFlight { handoff.cancel() }
            case .blocked:
                break
            }
        }
        defer { refreshDelivery() }
        switch mode {
        case .direct:
            // Extension-authored edits update the session anchor before UIKit
            // callbacks arrive. Any other caret or host-text mutation makes
            // the bounded replacement region unprovable and pauses the run.
            if machine.isCapturing,
               changedDocument || documentSession?.anchorIsCurrent() != true {
                // A new field means the proxy now reads a document this session
                // never wrote to. Drop the anchor first, so the `.targetChanged`
                // failure path cannot delete separator whitespace from the new
                // field on an exact scalar collision between the two contexts.
                if changedDocument {
                    documentSession?.invalidate()
                }
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

    /// Explicit one-tap pickup of the chip (#1003).
    func insertPendingPickup() {
        guard case let .chip(chip) = pickupOffering else { return }
        deliver(chip.text, offerID: chip.offerID)
    }

    /// The user declining the chip. The claim is recorded so it does not come
    /// back on the next appearance; the transcript stays in History.
    func dismissPendingPickup() {
        guard case let .chip(chip) = pickupOffering else { return }
        deliveryStore.claimOffer(chip.offerID)
        pickupOffering = .none
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
        // Every failure that can follow a started capture must clean up the
        // session-owned separator. An interruption or a target change after a
        // whitespace-only hypothesis ends in `.failed`, and would otherwise
        // leave a stray space in the host document.
        switch directState {
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

    // MARK: - Delivery (issues #1002, #1003, #1005)

    /// Advertises the open field and watches for a transcript the app has left
    /// pending. Both halves are cheap reads of the App Group; the store
    /// throttles the target rewrite.
    private func startDeliveryLoop() {
        guard pickupTask == nil else { return }
        pickupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshDelivery()
                try? await Task.sleep(for: Self.deliveryPollInterval)
            }
        }
    }

    private func refreshDelivery() {
        if case .blocked = mode {
            // Without Full Access there is no shared container to advertise
            // into and nothing to offer; the blocked strip already says so.
            pickupOffering = .none
            return
        }
        guard !isSecureField else {
            // Not merely "do not advertise": actively withdraw, because the
            // advertisement outlives its last refresh by design and the app
            // would otherwise still see an open target for a password field.
            deliveryStore.clearTarget()
            pickupOffering = .none
            return
        }
        // Preferences are app-owned and the user can change them while this
        // keyboard stays on screen. Re-reading them here is one small App Group
        // read per tick, and it stops hand-back or auto-pickup decisions
        // applying a choice the user has already superseded.
        deliveryPreferences = deliveryStore.preferences()
        publishTargetIfPossible()
        evaluatePickup()
    }

    private func publishTargetIfPossible() {
        guard let currentDocumentIdentifier, !isSecureField else { return }
        deliveryStore.publishTarget(
            documentIdentifier: currentDocumentIdentifier,
            isSecureField: false
        )
    }

    /// The decision, the text, and the claimed identifier all come from **one**
    /// snapshot of the offer. Reading the store twice let the app replace the
    /// offer in between, so the keyboard could insert offer A's text while
    /// claiming — and so silently burning — offer B.
    private func evaluatePickup() {
        let offer = deliveryStore.pendingOffer()
        let offering = KeyboardPickupPolicy.offering(
            offer: offer,
            claim: deliveryStore.claim(),
            currentDocumentIdentifier: currentDocumentIdentifier,
            isSecureField: isSecureField,
            handoffInFlight: handoff.isInFlight || machine.isCapturing,
            preferences: deliveryPreferences
        )
        if case let .autoInsert(text) = offering, let offer {
            deliver(text, offerID: offer.offerID)
            return
        }
        pickupOffering = offering
    }

    /// Inserts once and records the claim afterwards, so a death between the
    /// two leaves the offer retryable rather than losing the transcript.
    private func deliver(_ text: String, offerID: UUID) {
        // The insertion makes the host call back into `updateDocumentContext`.
        // Claiming happens after the proxy accepts the text, so guard the
        // window in between rather than letting a re-entrant pass insert twice.
        guard let proxyInsert, !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        proxyInsert(text)
        deliveryStore.claimOffer(offerID)
        pickupOffering = .none
        handBackAfterInsertIfPermitted()
    }

    /// Hands the keyboard back after a successful insertion (#1005). Only when
    /// exactly two keyboards are enabled: `advanceToNextInputMode()` moves to
    /// the *next* one, and with three or more that is not the one the user was
    /// typing on.
    private func handBackAfterInsertIfPermitted() {
        guard KeyboardHandBackPolicy.shouldAdvanceToNextInputMode(
            preferences: deliveryPreferences,
            activeInputModeCount: activeInputModeCount
        ) else {
            return
        }
        handBack?()
    }

    private func refreshChips() {
        languageChipLabel = languageSelection.quickIdentifiers.count > 1
            ? KeyboardLanguageSelection.chipLabel(for: languageSelection.selectedIdentifier)
            : nil
        profileChipLabel = profileSelection.availableProfiles.count > 1 ? profileSelection.chipLabel : nil
    }
}
