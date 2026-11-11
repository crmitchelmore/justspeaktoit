#if os(iOS)
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

    var credentialFallbackReason: String {
        credentialsAvailable ? "no API key" : "API keys unavailable — retry when access is restored"
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
        let mode: KeyboardDictationTranscriptionMode = transcriptionMode == .batch ? .batch : .streaming
        let model = transcriptionMode == .batch ? batchTranscriptionModel : selectedModel
        KeyboardDictationPreferencesStore.shared.publishAppProfileSelection(
            configuration: KeyboardAppProfileConfiguration(
                transcriptionMode: mode,
                transcriptionModelIdentifier: model,
                languageIdentifier: preferredLocaleIdentifier,
                postProcessingEnabled: postProcessingEnabled,
                postProcessingModelIdentifier: postProcessingModel
            )
        )
    }
}
#endif
