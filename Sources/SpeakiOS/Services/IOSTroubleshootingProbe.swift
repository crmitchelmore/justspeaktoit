#if os(iOS)
import AVFoundation
import Foundation
import Speech
import SpeakCore

/// Gathers what the Troubleshooting page needs (issue #1634) from the live
/// settings, permissions and keyboard heartbeat. The verdicts are decided by
/// `MobileTroubleshooting` in SpeakCore.
@MainActor
enum IOSTroubleshootingProbe {
    /// Providers whose key `APIKeyCredentialWriter` can check with a request.
    static let verifiableKeyEntryIDs: Set<String> = ["deepgram", "elevenlabs", "meta", "azure"]

    struct SelectedModel: Equatable {
        let identifier: String
        let purpose: ModelCredentialPurpose
        let runsOnDevice: Bool
    }

    static func gather(
        settings: AppSettings,
        keyboardOffered: Bool,
        rejectedKeyIdentifiers: Set<String> = []
    ) async -> MobileTroubleshooting.Input {
        await settings.ensureKeysLoaded()
        let model = selectedModel(settings)
        return MobileTroubleshooting.Input(
            microphone: microphonePermission(),
            speechRecognition: model.runsOnDevice ? speechPermission() : nil,
            recogniser: model.runsOnDevice ? await recogniser(settings) : .notRequired,
            transcription: transcriptionProvider(model, settings: settings, rejected: rejectedKeyIdentifiers),
            postProcessingEnabled: settings.postProcessingEnabled,
            postProcessing: postProcessingProvider(settings, rejected: rejectedKeyIdentifiers),
            keyboard: keyboardOffered ? keyboardState() : .notOffered
        )
    }

    static func selectedModel(_ settings: AppSettings) -> SelectedModel {
        if settings.transcriptionMode == .batch {
            let identifier = settings.batchTranscriptionModel
            return SelectedModel(
                identifier: identifier, purpose: .batchTranscription,
                runsOnDevice: IOSBatchTranscriptionRoute.route(for: identifier) == .appleSpeechAnalyzer
            )
        }
        return SelectedModel(
            identifier: settings.selectedModel, purpose: .liveTranscription,
            runsOnDevice: ModelCatalog.isOnDeviceLiveTranscriptionModel(settings.selectedModel)
        )
    }

    /// The API Keys entry id for a stored credential identifier.
    static func keyEntryID(for credentialIdentifier: String) -> String {
        if credentialIdentifier == AzureSpeechConfiguration.credentialIdentifier { return "azure" }
        let suffix = ".apiKey"
        return credentialIdentifier.hasSuffix(suffix)
            ? String(credentialIdentifier.dropLast(suffix.count))
            : credentialIdentifier
    }

    struct VerificationTarget: Equatable {
        let identifier: String
        let entryID: String
        let providerName: String
        let key: String
    }

    /// The saved key a finding's Check key action sends to its provider, or
    /// nil when there is no key or the provider has no check.
    static func verificationTarget(
        for check: MobileTroubleshooting.Check, settings: AppSettings
    ) -> VerificationTarget? {
        let model: String
        let purpose: ModelCredentialPurpose
        switch check {
        case .transcriptionKey:
            let selected = selectedModel(settings)
            (model, purpose) = (selected.identifier, selected.purpose)
        case .postProcessingKey:
            (model, purpose) = (settings.postProcessingModel, .postProcessing)
        default:
            return nil
        }
        guard case .apiKey(let identifier, let name) = ModelCredentialResolver.requirement(
            for: model, purpose: purpose
        ) else { return nil }
        let entryID = keyEntryID(for: identifier)
        let key = savedKey(for: model, purpose: purpose, settings: settings)
        guard verifiableKeyEntryIDs.contains(entryID), !key.isEmpty else { return nil }
        return VerificationTarget(identifier: identifier, entryID: entryID, providerName: name, key: key)
    }

    // MARK: - Providers

    static func transcriptionProvider(
        _ model: SelectedModel, settings: AppSettings, rejected: Set<String>
    ) -> MobileTroubleshooting.Provider {
        guard case .apiKey(let identifier, let name) = ModelCredentialResolver.requirement(
            for: model.identifier, purpose: model.purpose
        ) else { return MobileTroubleshooting.Provider(name: nil, key: .notRequired) }
        let key = savedKey(for: model.identifier, purpose: model.purpose, settings: settings)
        return provider(identifier: identifier, name: name, key: key, settings: settings, rejected: rejected)
    }

    /// The key the model's route would send, resolved the way capture does.
    static func savedKey(for model: String, purpose: ModelCredentialPurpose, settings: AppSettings) -> String {
        switch purpose {
        case .batchTranscription: return settings.batchAPIKey(for: model)
        case .postProcessing: return settings.postProcessingAPIKey(for: model)
        case .liveTranscription, .voiceOutput:
            return LiveTranscriptionRouting.route(for: model).map(settings.liveAPIKey(for:)) ?? ""
        }
    }

    static func postProcessingProvider(
        _ settings: AppSettings, rejected: Set<String>
    ) -> MobileTroubleshooting.Provider {
        let model = settings.postProcessingModel
        guard case .apiKey(let identifier, let name) = ModelCredentialResolver.requirement(
            for: model, purpose: .postProcessing
        ) else { return MobileTroubleshooting.Provider(name: nil, key: .notRequired) }
        let key = savedKey(for: model, purpose: .postProcessing, settings: settings)
        return provider(identifier: identifier, name: name, key: key, settings: settings, rejected: rejected)
    }

    private static func provider(
        identifier: String, name: String, key: String, settings: AppSettings, rejected: Set<String>
    ) -> MobileTroubleshooting.Provider {
        let canVerify = verifiableKeyEntryIDs.contains(keyEntryID(for: identifier))
        let state: MobileTroubleshooting.KeyState
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = rejected.contains(identifier) ? .rejected : .present
        } else {
            state = settings.credentialsAvailable ? .missing : .unreadable
        }
        return MobileTroubleshooting.Provider(name: name, key: state, canVerify: canVerify)
    }

    // MARK: - System state

    static func microphonePermission() -> MobileTroubleshooting.Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func speechPermission() -> MobileTroubleshooting.Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Asks the system which recogniser languages it supports and has
    /// installed. Only read when the page opens, never on the capture path.
    static func recogniser(_ settings: AppSettings) async -> MobileTroubleshooting.Recogniser {
        let locale = Locale(identifier: TranscriptionLanguageCatalog.localeIdentifier(
            for: settings.preferredLocaleIdentifier
        ))
        if #available(iOS 26.0, *) {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                return .unsupportedLanguage
            }
            let installed = await SpeechTranscriber.installedLocales
            let tag = supported.identifier(.bcp47)
            return installed.contains { $0.identifier(.bcp47) == tag } ? .ready : .needsDownload
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return .unsupportedLanguage }
        return recognizer.isAvailable ? .ready : .unavailable
    }

    static func keyboardState() -> MobileTroubleshooting.Keyboard {
        guard let observation = KeyboardHandoffStore.shared.extensionObservation() else { return .notAdded }
        return observation.hadFullAccess ? .ready : .needsFullAccess
    }
}
#endif
