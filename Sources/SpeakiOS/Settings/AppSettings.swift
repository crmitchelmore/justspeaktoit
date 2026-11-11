#if os(iOS)
import Combine
import Foundation
import OSLog
import SpeakCore
import SpeakSync
import UIKit

/// Simple UserDefaults-based settings for iOS app.
///
/// API keys are published here and written through `AppSettingsSecrets`;
/// identifiers and lookups live in `AppSettings+Credentials`, launch-time
/// loaders in `AppSettings+LaunchValues` and supported models in
/// `AppSettings+Models`.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    /// Keys, defaults and value domains shared with the macOS store.
    typealias Shared = SharedApplicationPreferences

    @Published public var selectedModel: String {
        didSet {
            defaults.set(selectedModel, forKey: DefaultsKey.selectedModel.storageKey)
            liveTranscriptionSelection.remember(selectedModel)
            liveTranscriptionSelection.persist(to: defaults)
            publishKeyboardProfileSelection()
        }
    }

    /// Per-placement memory of the user's live transcription model choices.
    /// Keeping the on-device and remote picks apart is what stops a remote
    /// choice such as Soniox being replaced by the catalogue default when the
    /// user visits local mode.
    public private(set) var liveTranscriptionSelection: LiveTranscriptionSelection

    @Published public var transcriptionMode: IOSTranscriptionMode {
        didSet {
            defaults.set(transcriptionMode.rawValue, forKey: DefaultsKey.transcriptionMode.rawValue)
            publishKeyboardProfileSelection()
        }
    }

    /// The remote sub-mode the user last chose, remembered while they are in
    /// local mode so returning to remote restores streaming or batch.
    @Published public var rememberedRemoteTranscriptionMode: IOSTranscriptionMode {
        didSet {
            defaults.set(
                rememberedRemoteTranscriptionMode.rawValue,
                forKey: DefaultsKey.rememberedRemoteTranscriptionMode.rawValue
            )
        }
    }

    @Published public var batchTranscriptionModel: String {
        didSet {
            let normalized = ModelCatalog.normalizedBatchTranscriptionModel(batchTranscriptionModel)
            if normalized != batchTranscriptionModel {
                batchTranscriptionModel = normalized
            } else {
                defaults.set(batchTranscriptionModel, forKey: DefaultsKey.batchTranscriptionModel.storageKey)
                publishKeyboardProfileSelection()
            }
        }
    }

    @Published public var deepgramAPIKey: String = "" {
        didSet { secrets.persist(deepgramAPIKey, identifier: Self.deepgramKeyID) }
    }
    @Published public var openRouterAPIKey: String = "" {
        didSet { secrets.persist(openRouterAPIKey, identifier: Self.openRouterKeyID) }
    }
    @Published public var openAIAPIKey: String = "" {
        didSet { secrets.persist(openAIAPIKey, identifier: Self.openAIKeyID) }
    }
    @Published public var elevenLabsAPIKey: String = "" {
        didSet { secrets.persist(elevenLabsAPIKey, identifier: Self.elevenLabsKeyID) }
    }

    /// API keys for providers that use the shared `StreamingTranscriptionClient`
    /// path (Cartesia today; Gladia/Modulate/AssemblyAI/Soniox as they are
    /// ported). Keyed by the provider's `apiKeyIdentifier`.
    @Published public var cartesiaAPIKey: String = "" {
        didSet { secrets.persist(cartesiaAPIKey, identifier: Self.cartesiaKeyID) }
    }
    @Published public var sonioxAPIKey: String = "" {
        didSet { secrets.persist(sonioxAPIKey, identifier: Self.sonioxKeyID) }
    }
    @Published public var modulateAPIKey: String = "" {
        didSet { secrets.persist(modulateAPIKey, identifier: Self.modulateKeyID) }
    }
    @Published public var assemblyAIAPIKey: String = "" {
        didSet { secrets.persist(assemblyAIAPIKey, identifier: Self.assemblyAIKeyID) }
    }
    @Published public var gladiaAPIKey: String = "" {
        didSet { secrets.persist(gladiaAPIKey, identifier: Self.gladiaKeyID) }
    }
    @Published public var googleAPIKey: String = "" {
        didSet { secrets.persist(googleAPIKey, identifier: Self.googleKeyID) }
    }
    @Published public var xAIAPIKey: String = "" {
        didSet { secrets.persist(xAIAPIKey, identifier: Self.xAIKeyID) }
    }
    @Published public var smallestAPIKey: String = "" {
        didSet { secrets.persist(smallestAPIKey, identifier: Self.smallestKeyID) }
    }
    @Published public var reson8APIKey: String = "" {
        didSet { secrets.persist(reson8APIKey, identifier: Self.reson8KeyID) }
    }
    @Published public var stepfunAPIKey: String = "" {
        didSet { secrets.persist(stepfunAPIKey, identifier: Self.stepfunKeyID) }
    }
    @Published public var speechmaticsAPIKey: String = "" {
        didSet { secrets.persist(speechmaticsAPIKey, identifier: Self.speechmaticsKeyID) }
    }
    @Published public var revAIAPIKey: String = "" {
        didSet { secrets.persist(revAIAPIKey, identifier: Self.revAIKeyID) }
    }
    @Published public var mistralAPIKey: String = "" {
        didSet { secrets.persist(mistralAPIKey, identifier: Self.mistralKeyID) }
    }
    @Published public var azureAPIKey: String = "" {
        didSet { secrets.persist(azureAPIKey, identifier: Self.azureKeyID) }
    }
    @Published public var alibabaAPIKey: String = "" {
        didSet { secrets.persist(alibabaAPIKey, identifier: Self.alibabaKeyID) }
    }
    @Published public var metaAPIKey: String = "" {
        didSet { secrets.persist(metaAPIKey, identifier: Self.metaKeyID) }
    }

    @Published public var transcriptionKeywords: String {
        didSet { defaults.set(transcriptionKeywords, forKey: DefaultsKey.transcriptionKeywords.storageKey) }
    }

    let defaults: UserDefaults
    let secrets: AppSettingsSecrets
    @Published public private(set) var credentialsAvailable = false

    /// Opt-in (issue #999): re-transcribe offline on-device captures with the
    /// selected cloud batch model once the network returns. Off by default
    /// because it spends provider credit without a fresh tap.
    @Published public var upgradeOfflineTranscriptsWhenOnline: Bool {
        didSet {
            self.defaults.set(
                self.upgradeOfflineTranscriptsWhenOnline,
                forKey: DefaultsKey.upgradeOfflineTranscriptsWhenOnline.storageKey
            )
        }
    }

    /// Whether a cancelled recording's audio stays in Saved Recordings to transcribe later.
    @Published public var keepAudioOnCancel: Bool {
        didSet { defaults.set(keepAudioOnCancel, forKey: DefaultsKey.keepAudioOnCancel.storageKey) }
    }

    @Published public var liveActivitiesEnabled: Bool {
        didSet { defaults.set(liveActivitiesEnabled, forKey: DefaultsKey.liveActivitiesEnabled.rawValue) }
    }

    var transcriptReadyNotificationsDidDisable: (() -> Void)?

    @Published public var transcriptReadyNotificationsEnabled: Bool {
        didSet {
            save(transcriptReadyNotificationsEnabled, .transcriptReadyNotificationsEnabled)
            if !self.transcriptReadyNotificationsEnabled { self.transcriptReadyNotificationsDidDisable?() }
        }
    }

    @Published var transcriptClipboardLifetime: TranscriptClipboardLifetime {
        didSet { save(transcriptClipboardLifetime.rawValue, .transcriptClipboardLifetimeSeconds) }
    }

    @Published var transcriptAllowsUniversalClipboard: Bool {
        didSet { save(transcriptAllowsUniversalClipboard, .transcriptUniversalClipboard) }
    }

    @Published private(set) var transcriptClipboardNoticeVersion: Int

    @Published public var visualDensity: AppVisualDensity {
        didSet { defaults.set(visualDensity.rawValue, forKey: DefaultsKey.visualDensity.storageKey) }
    }

    @Published public var autoStartRecording: Bool {
        didSet { defaults.set(autoStartRecording, forKey: DefaultsKey.autoStartRecording.rawValue) }
    }

    /// Hands-free dictation: recording is driven by Apple's on-device speech
    /// detector rather than the record button. Off by default, and inert below
    /// iOS 26 where `SpeechDetector` does not exist. The defaults key matches
    /// macOS so the two platforms stay in step.
    @Published public var handsFreeDictationEnabled: Bool {
        didSet {
            defaults.set(handsFreeDictationEnabled, forKey: DefaultsKey.handsFreeDictationEnabled.storageKey)
        }
    }

    @Published public var preferredLocaleIdentifier: String {
        didSet {
            defaults.set(preferredLocaleIdentifier, forKey: DefaultsKey.preferredLocale.storageKey)
            KeyboardDictationPreferencesStore.shared.mirrorAppPreference(
                selectedIdentifier: preferredLocaleIdentifier
            )
            publishKeyboardProfileSelection()
        }
    }

    /// What happens to the transcript when a hardware-triggered recording (Action Button,
    /// Siri, Shortcuts, Lock Screen widget, Back Tap, Control Center) stops.
    @Published public var hardwareTriggerDestination: HardwareTriggerDestination {
        didSet {
            defaults.set(hardwareTriggerDestination.rawValue, forKey: DefaultsKey.hardwareTriggerDestination.rawValue)
        }
    }

    /// Whether a headless capture (Control, Action Button, Siri, Shortcuts)
    /// finishes itself after a run of silence (issue #1012).
    ///
    /// Off by default and staying that way. Auto-stop is a genuine improvement
    /// for people who dictate in bursts and a genuine regression for people who
    /// think mid-sentence, and there is no way to tell which someone is without
    /// asking. Turning this on for everybody would cut some of them off.
    @Published public var autoStopOnSilenceEnabled: Bool {
        didSet { defaults.set(autoStopOnSilenceEnabled, forKey: DefaultsKey.autoStopOnSilenceEnabled.rawValue) }
    }

    /// How long silence must hold before an auto-stopping capture finishes.
    /// Clamped into `CaptureEndPointingPolicy.silenceWindowRange`.
    @Published public var autoStopSilenceSeconds: TimeInterval {
        didSet {
            let clamped = CaptureEndPointingPolicy.silenceWindow(configured: autoStopSilenceSeconds)
            if clamped != autoStopSilenceSeconds {
                autoStopSilenceSeconds = clamped
            } else {
                defaults.set(autoStopSilenceSeconds, forKey: DefaultsKey.autoStopSilenceSeconds.rawValue)
            }
        }
    }

    // MARK: - Post-Processing Settings

    @Published public var postProcessingEnabled: Bool {
        didSet {
            defaults.set(postProcessingEnabled, forKey: DefaultsKey.postProcessingEnabled.storageKey)
            publishKeyboardProfileSelection()
        }
    }

    /// Device-local metadata discovery; intentionally outside automatic settings transfer.
    @Published public var cleanupModelDiscoveryEnabled: Bool {
        didSet { defaults.set(cleanupModelDiscoveryEnabled, forKey: Shared.cleanupModelDiscoveryEnabled.iOS.key) }
    }

    @Published public var postProcessingModel: String {
        didSet {
            defaults.set(postProcessingModel, forKey: DefaultsKey.postProcessingModel.storageKey)
            publishKeyboardProfileSelection()
        }
    }

    @Published public var autoPostProcess: Bool {
        didSet { defaults.set(autoPostProcess, forKey: DefaultsKey.autoPostProcess.rawValue) }
    }

    /// - Parameters:
    ///   - defaults: Backing store. Injectable so persistence behaviour (including
    ///     relaunch restoration) is testable without touching the user's defaults.
    ///   - loadsSecureStorage: When false, the keychain bootstrap and default-provider
    ///     selection are skipped. Tests use this to exercise persistence in isolation.
    init(
        defaults: UserDefaults = .standard,
        loadsSecureStorage: Bool = true,
        credentialStorage: SecureStorage? = nil
    ) {
        self.defaults = defaults
        self.secrets = AppSettingsSecrets(
            storage: credentialStorage ?? Self.canonicalCredentialStorage,
            migratesLegacyCredentials: credentialStorage == nil
        )
        let selected = Self.storedSelectedModel(in: defaults)
        let mode = IOSTranscriptionMode(
            rawValue: defaults.string(forKey: DefaultsKey.transcriptionMode.rawValue) ?? ""
        ) ?? .streaming
        var selection = LiveTranscriptionSelection(defaults: defaults)
        // Existing installs upgrade with their active model remembered for the
        // placement it belongs to; the other placement stays empty until chosen.
        selection.rememberIfMissing(selected)
        self.liveTranscriptionSelection = selection
        self.rememberedRemoteTranscriptionMode = IOSTranscriptionMode(
            rawValue: defaults.string(forKey: DefaultsKey.rememberedRemoteTranscriptionMode.rawValue) ?? ""
        ) ?? mode
        self.selectedModel = selected
        self.transcriptionMode = mode
        self.batchTranscriptionModel = Shared.batchTranscriptionModel.iOS.value(in: defaults)
        // API keys load asynchronously from the canonical secure storage (with
        // legacy migration) once `startLoadingCredentials()` runs.
        self.transcriptionKeywords = Shared.transcriptionKeywords.iOS.value(in: defaults)
        self.transcriptReadyNotificationsEnabled = defaults.bool(
            forKey: DefaultsKey.transcriptReadyNotificationsEnabled.storageKey
        )
        self.upgradeOfflineTranscriptsWhenOnline = defaults.bool(
            forKey: DefaultsKey.upgradeOfflineTranscriptsWhenOnline.storageKey
        )
        // Default Live Activities to true if not set
        self.liveActivitiesEnabled = defaults.object(forKey: DefaultsKey.liveActivitiesEnabled.rawValue) as? Bool
            ?? true
        self.keepAudioOnCancel = Self.storedKeepAudioOnCancel(in: defaults)
        let clipboardPolicy = Self.storedClipboardPolicy(in: defaults)
        self.transcriptClipboardLifetime = clipboardPolicy.lifetime
        self.transcriptAllowsUniversalClipboard = clipboardPolicy.allowsUniversalClipboard
        self.transcriptClipboardNoticeVersion = Self.storedClipboardNoticeVersion(in: defaults)
        self.visualDensity = Shared.visualDensity.iOS.value(in: defaults)
        self.autoStartRecording = defaults.bool(forKey: DefaultsKey.autoStartRecording.rawValue)
        self.handsFreeDictationEnabled = Shared.handsFreeDictationEnabled.iOS.value(in: defaults)
        self.preferredLocaleIdentifier = Shared.preferredLocale.iOS.value(in: defaults)
        self.hardwareTriggerDestination = Self.storedHardwareTriggerDestination(in: defaults)
        self.autoStopOnSilenceEnabled = defaults.bool(forKey: DefaultsKey.autoStopOnSilenceEnabled.rawValue)
        self.autoStopSilenceSeconds = Self.storedAutoStopSilenceSeconds(in: defaults)
        self.postProcessingEnabled = Shared.postProcessingEnabled.iOS.value(in: defaults)
        self.cleanupModelDiscoveryEnabled = Shared.cleanupModelDiscoveryEnabled.iOS.value(in: defaults)
        self.postProcessingModel = Self.storedPostProcessingModel(in: defaults)
        self.autoPostProcess = defaults.bool(forKey: DefaultsKey.autoPostProcess.rawValue)
        // `didSet` never fires during init, so persist the seeded memory explicitly.
        selection.persist(to: defaults)
        defaults.set(
            self.rememberedRemoteTranscriptionMode.rawValue,
            forKey: DefaultsKey.rememberedRemoteTranscriptionMode.rawValue
        )
        if loadsSecureStorage { startLoadingCredentials() }
    }

}

extension AppSettings {
    private func save(_ value: Any, _ key: DefaultsKey) {
        defaults.set(value, forKey: key.storageKey)
    }

    // Each credential is reloaded without overwriting a locked Keychain entry.
    @discardableResult
    public func reloadSyncedAPIKeys() async -> Bool {
        guard await secrets.storage.preloadAndReportSuccess() else { return false }
        for key in Self.syncedAPIKeys {
            await secrets.reload(identifier: key.identifier) { self[keyPath: key.keyPath] = $0 }
        }
        credentialsAvailable = true
        return true
    }

    func applyDefaultRemoteProviderIfNeeded(_ modelID: String) {
        guard liveTranscriptionSelection.rememberedModel(for: .remote) == nil else { return }
        let isRemoteStreaming = transcriptionMode == .streaming
            && !ModelCatalog.isOnDeviceLiveTranscriptionModel(selectedModel)
        if isRemoteStreaming {
            selectedModel = modelID
        } else {
            liveTranscriptionSelection.remember(modelID)
            liveTranscriptionSelection.persist(to: defaults)
        }
    }

    func acknowledgeTranscriptClipboardNotice() {
        self.transcriptClipboardNoticeVersion = 1
        self.defaults.set(1, forKey: DefaultsKey.transcriptClipboardNoticeVersion.rawValue)
    }

}
#endif
