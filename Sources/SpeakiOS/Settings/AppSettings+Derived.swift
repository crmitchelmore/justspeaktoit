#if os(iOS)
import Combine
import Foundation
import SpeakCore

/// Values and actions derived from the published preferences.
extension AppSettings {
    /// Where transcription currently runs, derived from the active model.
    var transcriptionLocation: IOSTranscriptionLocation {
        ModelCatalog.isOnDeviceLiveTranscriptionModel(selectedModel) && transcriptionMode == .streaming
            ? .local
            : .remote
    }

    /// The remote sub-mode to show: the live value when remote is active,
    /// otherwise the remembered one.
    var remoteTranscriptionMode: IOSTranscriptionMode {
        transcriptionLocation == .local ? rememberedRemoteTranscriptionMode : transcriptionMode
    }

    /// Switches between local and remote transcription, restoring the model and
    /// sub-mode the user last chose on the side they return to. Defaults apply
    /// only when that side has no remembered selection.
    func selectTranscriptionLocation(_ location: IOSTranscriptionLocation) {
        switch location {
        case .local:
            selectedModel = liveTranscriptionSelection.model(
                for: .onDevice,
                activeModel: selectedModel,
                selectableModelIDs: Self.selectableLiveModelIDs
            )
            transcriptionMode = .streaming
        case .remote:
            selectRemoteTranscriptionMode(rememberedRemoteTranscriptionMode)
        }
    }

    func selectRemoteTranscriptionMode(_ mode: IOSTranscriptionMode) {
        rememberedRemoteTranscriptionMode = mode
        if mode == .streaming {
            selectedModel = liveTranscriptionSelection.model(
                for: .remote,
                activeModel: selectedModel,
                selectableModelIDs: Self.selectableLiveModelIDs
            )
        }
        transcriptionMode = mode
    }

    /// Re-configure provider after onboarding or API key changes.
    ///
    /// Only fills a gap: once the user has picked a remote streaming model, a
    /// newly saved key must not silently move them onto another provider.
    public func reconfigureDefaultProvider() {
        if hasDeepgramKey {
            applyDefaultRemoteProviderIfNeeded("deepgram/nova-3-streaming")
        } else if hasElevenLabsKey {
            applyDefaultRemoteProviderIfNeeded("elevenlabs/scribe-v2-streaming")
        }
    }

    /// Read where no settings object is in reach, such as the recorder's cancel path.
    nonisolated public static func storedKeepAudioOnCancel(in defaults: UserDefaults = .standard) -> Bool {
        Shared.keepAudioOnCancel.iOS.value(in: defaults)
    }

    /// Whether hands-free dictation can actually run on this device.
    public var handsFreeDictationSupported: Bool {
        AppleLocalModels.supportsSpeechDetector
    }

    /// The setting only takes effect where the detector exists, so a value
    /// synced from a newer OS cannot change behaviour on an older one.
    public var handsFreeDictationActive: Bool {
        handsFreeDictationEnabled && handsFreeDictationSupported
    }

    public var preferredModelLanguage: String? {
        TranscriptionLanguageCatalog.providerLanguage(for: preferredLocaleIdentifier)
    }

    var transcriptClipboardPolicy: TranscriptClipboardPolicy {
        TranscriptClipboardPolicy(
            lifetime: self.transcriptClipboardLifetime,
            allowsUniversalClipboard: self.transcriptAllowsUniversalClipboard
        )
    }

    var isTranscriptClipboardNoticePending: Bool {
        self.transcriptClipboardNoticeVersion < 1
    }

    /// Remote consumers must not interpret a failed load as a missing key.
    /// Local models can continue without Keychain access.
    func requireAvailableCredentials(for model: String, purpose: ModelCredentialPurpose) throws {
        guard !credentialsAvailable,
              ModelCredentialResolver.requirement(for: model, purpose: purpose) != .notRequired else { return }
        throw CredentialLoadingError.unavailable
    }

    /// Publishes one coherent, non-secret keyboard capability snapshot whenever
    /// any owning setting changes. App activation calls this too as reconciliation.
    public func publishKeyboardProfileSelection() {
        let configuration = keyboardProfileConfiguration
        lastPublishedKeyboardAvailability = configuration.availability
        KeyboardDictationPreferencesStore.shared.publishAppProfileSelection(configuration: configuration)
    }

    /// Republishes only when the keyboard-visible availability changed, so a
    /// saved, synced or removed key reaches the profile menu without churning
    /// the catalogue revision on every unrelated settings change.
    func publishKeyboardProfileSelectionIfAvailabilityChanged() {
        guard keyboardProfileConfiguration.availability != lastPublishedKeyboardAvailability else { return }
        publishKeyboardProfileSelection()
    }

    /// Keys load, sync and change outside the didSets that publish the
    /// keyboard catalogue; follow them so the menu never shows a stale state.
    func observeKeyboardProfileAvailability() {
        keyboardAvailabilityObservation = objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publishKeyboardProfileSelectionIfAvailabilityChanged() }
    }

    var keyboardProfileConfiguration: KeyboardAppProfileConfiguration {
        let usesBatch = transcriptionMode == .batch
        let model = usesBatch ? batchTranscriptionModel : selectedModel
        var configuration = KeyboardAppProfileConfiguration(
            transcriptionMode: usesBatch ? .batch : .streaming,
            transcriptionModelIdentifier: model,
            languageIdentifier: preferredLocaleIdentifier,
            postProcessingEnabled: postProcessingEnabled,
            postProcessingModelIdentifier: postProcessingModel
        )
        configuration.availability = profileAvailability(
            transcriptionModel: model,
            usesBatch: usesBatch,
            postProcessingModel: postProcessingEnabled ? postProcessingModel : nil
        )
        return configuration
    }

    // MARK: - Availability (report unavailable, never substitute)

    /// Whether `modelID` can run on iOS in this mode with the stored credentials.
    func transcriptionAvailability(for modelID: String, usesBatch: Bool) -> TranscriptionModelAvailability {
        let executable: Bool
        let credential: String
        if usesBatch {
            executable = Self.supportsBatchModel(modelID)
            credential = batchAPIKey(for: modelID)
        } else {
            let route = LiveTranscriptionRouting.route(for: modelID)
            executable = route?.isSupportedOnIOS == true
            credential = route.map { liveAPIKey(for: $0) } ?? ""
        }
        return .evaluate(
            requirement: ModelCredentialResolver.requirement(
                for: modelID, purpose: usesBatch ? .batchTranscription : .liveTranscription
            ),
            isExecutableHere: executable,
            credentialsLoaded: credentialsAvailable,
            credential: credential
        )
    }

    /// Refuses a run whose model cannot run, rather than substituting another.
    func requireTranscriptionAvailable(_ modelID: String, usesBatch: Bool) throws {
        let availability = transcriptionAvailability(for: modelID, usesBatch: usesBatch)
        guard !availability.isAvailable else { return }
        throw TranscriptionModelUnavailableError(
            modelIdentifier: modelID,
            modelName: ModelCatalog.friendlyName(for: modelID),
            availability: availability
        )
    }

    func postProcessingAvailability(for modelID: String) -> TranscriptionModelAvailability {
        let listed = Self.postProcessingModels.contains { $0.id == modelID }
            || CleanupModelSelection.modelID(from: modelID) != nil
        let executable = listed
            && (modelID != AppleLocalModels.foundationModelID || AppleFoundationModelPolisher.isAvailable)
        return .evaluate(
            requirement: ModelCredentialResolver.requirement(for: modelID, purpose: .postProcessing),
            isExecutableHere: executable,
            credentialsLoaded: credentialsAvailable,
            credential: postProcessingAPIKey(for: modelID)
        )
    }

    /// A profile is unavailable when its transcription model is, or when it
    /// polishes with a model that cannot run.
    func profileAvailability(
        transcriptionModel: String, usesBatch: Bool, postProcessingModel: String?
    ) -> TranscriptionModelAvailability {
        var parts = [transcriptionAvailability(for: transcriptionModel, usesBatch: usesBatch)]
        if let postProcessingModel, !postProcessingModel.isEmpty {
            parts.append(postProcessingAvailability(for: postProcessingModel))
        }
        return .first(of: parts)
    }
}
#endif
