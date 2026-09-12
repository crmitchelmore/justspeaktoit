#if os(iOS)
import Combine
import Foundation
import OSLog
import Security
import SpeakCore
import SpeakSync
import UIKit

// swiftlint:disable file_length

// MARK: - Hardware Trigger Destination

/// What happens to the transcript after a hardware-triggered recording stops.
///
/// Used by every "headless" entry point: Action Button (iPhone 15 Pro+),
/// Siri voice commands, the Shortcuts app, Lock Screen / Home Screen widget,
/// Control Center, Back Tap. The main in-app record-and-stop flow is
/// unaffected — it always shows the result on screen.
public enum HardwareTriggerDestination: String, CaseIterable, Identifiable, Sendable {
    /// Resolve the destination at stop time (issue #1008): the field the Just
    /// Speak keyboard is open in when there is one, otherwise the clipboard.
    /// Every capture also goes to History and iCloud, whichever lane runs.
    ///
    /// There is no "Mac" branch: see `AutoDestinationPolicy` for why the phone
    /// cannot tell a reachable Mac from a configured one.
    case auto

    /// Copy the transcript to the clipboard. Default — matches behaviour
    /// prior to the destination setting being added.
    case clipboard

    /// Copy to clipboard and run the configured post-processor (OpenRouter)
    /// asynchronously. Raw text is copied once and polished text is saved in
    /// History. Without a key, the raw copy remains available.
    case clipboardAndPostProcess

    /// Save to history only — don't touch the clipboard, don't post-process.
    /// Useful if the user wants to capture a thought without polluting the
    /// pasteboard with something they didn't choose to paste.
    case historyOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .clipboard: return "Copy to Clipboard"
        case .clipboardAndPostProcess: return "Copy & Polish"
        case .historyOnly: return "Save to History Only"
        }
    }

    public var summary: String {
        switch self {
        case .auto:
            return "Decided when recording stops: straight into the field if the Just Speak keyboard is open "
                + "there, otherwise the clipboard. Either way it is saved to History and pushed to iCloud, "
                + "and the Live Activity says which one happened."
        case .clipboard:
            return "Transcript is copied to the clipboard immediately when recording stops."
        case .clipboardAndPostProcess:
            return "Raw transcript is copied immediately. Polished text is saved in History."
        case .historyOnly:
            return "Transcript is saved to history. Clipboard and post-processing are skipped."
        }
    }
}

// MARK: - Settings Storage

public enum IOSTranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case streaming
    case batch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .batch: return "Batch"
        }
    }
}

/// Simple UserDefaults-based settings for iOS app.
@MainActor
public final class AppSettings: ObservableObject {
    // swiftlint:disable:previous type_body_length
    enum DefaultsKey: String, CaseIterable {
        case selectedModel
        case transcriptionMode
        case rememberedRemoteTranscriptionMode
        case batchTranscriptionModel
        case transcriptionKeywords
        case liveActivitiesEnabled
        case visualDensity
        case autoStartRecording
        case handsFreeDictationEnabled
        case preferredLocale
        case hardwareTriggerDestination
        case autoStopOnSilenceEnabled
        case autoStopSilenceSeconds
        case postProcessingEnabled
        case postProcessingModel
        case autoPostProcess
        case hasLaunchedBefore
    }

    public static let shared = AppSettings()

    @Published public var selectedModel: String {
        didSet {
            defaults.set(selectedModel, forKey: DefaultsKey.selectedModel.rawValue)
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

    /// Identifiers this build can actually select for live transcription.
    static var selectableLiveModelIDs: Set<String> {
        Set((ModelCatalog.onDeviceLiveTranscription + supportedLiveModels).map(\.id))
    }

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

    @Published public var batchTranscriptionModel: String {
        didSet {
            let normalized = ModelCatalog.normalizedBatchTranscriptionModel(batchTranscriptionModel)
            if normalized != batchTranscriptionModel {
                batchTranscriptionModel = normalized
            } else {
                defaults.set(batchTranscriptionModel, forKey: DefaultsKey.batchTranscriptionModel.rawValue)
                publishKeyboardProfileSelection()
            }
        }
    }

    @Published public var deepgramAPIKey: String {
        didSet { persistSecret(deepgramAPIKey, identifier: Self.deepgramKeyID) }
    }

    @Published public var openRouterAPIKey: String {
        didSet { persistSecret(openRouterAPIKey, identifier: Self.openRouterKeyID) }
    }

    @Published public var openAIAPIKey: String {
        didSet { persistSecret(openAIAPIKey, identifier: Self.openAIKeyID) }
    }

    @Published public var elevenLabsAPIKey: String {
        didSet { persistSecret(elevenLabsAPIKey, identifier: Self.elevenLabsKeyID) }
    }

    /// API keys for providers that use the shared `StreamingTranscriptionClient`
    /// path (Cartesia today; Gladia/Modulate/AssemblyAI/Soniox as they are
    /// ported). Keyed by the provider's `apiKeyIdentifier`.
    @Published public var cartesiaAPIKey: String {
        didSet { persistSecret(cartesiaAPIKey, identifier: Self.cartesiaKeyID) }
    }

    @Published public var sonioxAPIKey: String {
        didSet { persistSecret(sonioxAPIKey, identifier: Self.sonioxKeyID) }
    }

    @Published public var modulateAPIKey: String {
        didSet { persistSecret(modulateAPIKey, identifier: Self.modulateKeyID) }
    }

    @Published public var assemblyAIAPIKey: String {
        didSet { persistSecret(assemblyAIAPIKey, identifier: Self.assemblyAIKeyID) }
    }

    @Published public var gladiaAPIKey: String {
        didSet { persistSecret(gladiaAPIKey, identifier: Self.gladiaKeyID) }
    }

    @Published public var googleAPIKey: String {
        didSet { persistSecret(googleAPIKey, identifier: Self.googleKeyID) }
    }

    @Published public var xAIAPIKey: String {
        didSet { persistSecret(xAIAPIKey, identifier: Self.xAIKeyID) }
    }

    @Published public var speechmaticsAPIKey: String {
        didSet { persistSecret(speechmaticsAPIKey, identifier: Self.speechmaticsKeyID) }
    }

    @Published public var revAIAPIKey: String {
        didSet { persistSecret(revAIAPIKey, identifier: Self.revAIKeyID) }
    }

    @Published public var mistralAPIKey: String {
        didSet { persistSecret(mistralAPIKey, identifier: Self.mistralKeyID) }
    }

    @Published public var azureAPIKey: String {
        didSet { persistSecret(azureAPIKey, identifier: Self.azureKeyID) }
    }

    @Published public var metaAPIKey: String {
        didSet { persistSecret(metaAPIKey, identifier: Self.metaKeyID) }
    }

    @Published public var transcriptionKeywords: String {
        didSet { defaults.set(transcriptionKeywords, forKey: DefaultsKey.transcriptionKeywords.rawValue) }
    }

    // MARK: - Canonical secure storage for API keys (SpeakCore)
    //
    // Every API key is stored locally through SpeakCore's SecureStorage using the
    // same service/account as the macOS app. Cross-device transfer is handled only
    // by the explicit passphrase-encrypted CloudKit sync feature below; the base
    // Keychain item is deliberately not kSecAttrSynchronizable.
    static let deepgramKeyID = "deepgram.apiKey"
    static let openRouterKeyID = "openrouter.apiKey"
    static let openAIKeyID = "openai.apiKey"
    static let elevenLabsKeyID = "elevenlabs.apiKey"
    static let cartesiaKeyID = "cartesia.apiKey"
    static let sonioxKeyID = "soniox.apiKey"
    static let modulateKeyID = "modulate.apiKey"
    static let assemblyAIKeyID = "assemblyai.apiKey"
    static let gladiaKeyID = "gladia.apiKey"
    static let googleKeyID = "google.apiKey"
    static let xAIKeyID = "xai.apiKey"
    static let azureKeyID = AzureSpeechConfiguration.credentialIdentifier
    static let metaKeyID = "meta.apiKey"
    static let speechmaticsKeyID = "speechmatics.apiKey"
    static let revAIKeyID = "revai.apiKey"
    static let mistralKeyID = "mistral.apiKey"

    private static let credentialStorage = SecureStorage(
        configuration: SecureStorageConfiguration(
            service: "com.github.speakapp.credentials",
            masterAccount: "speak-app-secrets",
            legacyServices: ["com.justspeaktoit.credentials"],
            accessibility: .afterFirstUnlock
        )
    )

    /// The canonical API-key store, exposed so QR config transfer reads and
    /// writes the same keychain items the rest of the app uses. Exporting or
    /// importing against any other service silently produces keys the app
    /// never sees.
    static var canonicalCredentialStorage: SecureStorage { credentialStorage }

    private static let logger = SpeakLogger.logger(category: "AppSettings")
    private var keyChangeObserver: NSObjectProtocol?
    private var syncedKeyReloadDepth = 0
    private let credentials: SecureStorage
    private let migratesLegacyCredentials: Bool
    private var protectedDataObserver: NSObjectProtocol?
    private var keyLoadTask: Task<Bool, Never>?
    @Published public private(set) var credentialsAvailable = false

    enum CredentialLoadingError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "API keys could not be loaded. Retry when Keychain access is available."
        }
    }

    var credentialFallbackReason: String {
        credentialsAvailable ? "no API key" : "API keys unavailable — retry when access is restored"
    }

    /// Persists (or clears when empty) an API key on the canonical secure store.
    /// Keychain failures are logged rather than silently dropped so a key that
    /// appears saved but didn't persist is diagnosable from logs.
    private func persistSecret(_ value: String, identifier: String) {
        guard syncedKeyReloadDepth == 0 else { return }
        Task {
            do {
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await credentials.removeSecret(identifier: identifier)
                } else {
                    try await credentials.storeSecret(value, identifier: identifier)
                }
            } catch {
                Self.logger.error(
                    "Failed to persist secret \(identifier, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    @Published public var liveActivitiesEnabled: Bool {
        didSet { defaults.set(liveActivitiesEnabled, forKey: DefaultsKey.liveActivitiesEnabled.rawValue) }
    }

    @Published public var visualDensity: AppVisualDensity {
        didSet { defaults.set(visualDensity.rawValue, forKey: DefaultsKey.visualDensity.rawValue) }
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
            defaults.set(handsFreeDictationEnabled, forKey: DefaultsKey.handsFreeDictationEnabled.rawValue)
        }
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

    @Published public var preferredLocaleIdentifier: String {
        didSet {
            defaults.set(preferredLocaleIdentifier, forKey: DefaultsKey.preferredLocale.rawValue)
            KeyboardDictationPreferencesStore.shared.mirrorAppPreference(
                selectedIdentifier: preferredLocaleIdentifier
            )
            publishKeyboardProfileSelection()
        }
    }

    public var preferredModelLanguage: String? {
        TranscriptionLanguageCatalog.providerLanguage(for: preferredLocaleIdentifier)
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
            defaults.set(postProcessingEnabled, forKey: DefaultsKey.postProcessingEnabled.rawValue)
            publishKeyboardProfileSelection()
        }
    }

    @Published public var postProcessingModel: String {
        didSet {
            defaults.set(postProcessingModel, forKey: DefaultsKey.postProcessingModel.rawValue)
            publishKeyboardProfileSelection()
        }
    }

    @Published public var autoPostProcess: Bool {
        didSet { defaults.set(autoPostProcess, forKey: DefaultsKey.autoPostProcess.rawValue) }
    }

    public static let defaultPostProcessingPrompt = TranscriptCleanupPolicy.baseSystemPrompt

    public static let postProcessingModels = ModelCatalog.postProcessing.filter {
        !$0.id.hasPrefix("local/post-processing/")
    }

    /// - Parameters:
    ///   - defaults: Backing store. Injectable so persistence behaviour (including
    ///     relaunch restoration) is testable without touching the user's defaults.
    ///   - loadsSecureStorage: When false, the keychain bootstrap and default-provider
    ///     selection are skipped. Tests use this to exercise persistence in isolation.
    init( // swiftlint:disable:this function_body_length
        defaults: UserDefaults = .standard,
        loadsSecureStorage: Bool = true,
        credentialStorage: SecureStorage? = nil
    ) {
        self.defaults = defaults
        self.credentials = credentialStorage ?? Self.credentialStorage
        self.migratesLegacyCredentials = credentialStorage == nil
        let storedSelectedRaw = defaults.string(forKey: DefaultsKey.selectedModel.rawValue)
            ?? AppleLocalModels.preferredSpeechModelID
        let selectedRaw = ModelCatalog.normalizedLiveTranscriptionModel(storedSelectedRaw)
        // Normalise to canonical catalogue ids. Keep only models that this iOS
        // target can actually run; a previously stored macOS-only model falls
        // back to Apple Speech instead of leaking into the iPhone picker.
        let selectableLiveIDs = Set(
            (ModelCatalog.onDeviceLiveTranscription + Self.supportedLiveModels).map(\.id)
        )
        let selected: String
        if AppleLocalModels.isAppleSpeechModel(selectedRaw) {
            selected = selectedRaw
        } else if selectableLiveIDs.contains(selectedRaw) {
            selected = selectedRaw
        } else if selectedRaw.hasPrefix("apple/") {
            selected = selectedRaw
        } else if selectedRaw.hasPrefix("deepgram/") {
            selected = "deepgram/nova-3-streaming"
        } else if selectedRaw.hasPrefix("elevenlabs/") {
            selected = "elevenlabs/scribe-v2-streaming"
        } else if selectedRaw.hasPrefix("openai/") {
            selected = "openai/gpt-realtime-whisper-streaming"
        } else {
            selected = AppleLocalModels.preferredSpeechModelID
        }
        // API keys load asynchronously from the canonical secure storage (with
        // legacy migration) in the Task below.

        // Default Live Activities to true if not set
        let liveActivities = defaults.object(forKey: DefaultsKey.liveActivitiesEnabled.rawValue) as? Bool ?? true
        let density = AppVisualDensity(
            rawValue: defaults.string(forKey: DefaultsKey.visualDensity.rawValue) ?? ""
        ) ?? .normal
        let autoStart = defaults.bool(forKey: DefaultsKey.autoStartRecording.rawValue)
        let handsFree = defaults.bool(forKey: DefaultsKey.handsFreeDictationEnabled.rawValue)
        let preferredLocale = TranscriptionLanguageCatalog.normalizedIdentifier(
            defaults.string(forKey: DefaultsKey.preferredLocale.rawValue)
        )

        // Hardware trigger destination (Action Button, Siri, Shortcuts).
        // `.auto` is the default only for users who never made a choice: an
        // explicitly stored value is always honoured (issue #1008). Auto is a
        // superset of the old default — it copies to the clipboard except when
        // the Just Speak keyboard is demonstrably open in a text field, where
        // the words go into that field instead.
        //
        // A stored value this build cannot parse is *not* the same thing as no
        // stored value: it means a malformed, downgraded or migrated
        // preference, and defaulting it to Auto would silently opt that user
        // into suppressing the clipboard whenever a targeted keyboard offer
        // exists. Missing keeps the new default; unrecognised keeps the
        // pre-Auto behaviour it was last known to have.
        let hardwareDest: HardwareTriggerDestination
        if let hardwareDestRaw = defaults.string(forKey: DefaultsKey.hardwareTriggerDestination.rawValue) {
            hardwareDest = HardwareTriggerDestination(rawValue: hardwareDestRaw) ?? .clipboard
        } else {
            hardwareDest = .auto
        }

        // Post-processing settings
        let postEnabled = defaults.bool(forKey: DefaultsKey.postProcessingEnabled.rawValue)
        let storedPostModel = defaults.string(forKey: DefaultsKey.postProcessingModel.rawValue)
        let normalizedPostModel = ModelCatalog.normalizedPostProcessingModel(storedPostModel)
        let postModel = Self.postProcessingModels.contains { $0.id == normalizedPostModel }
            ? normalizedPostModel
            : ModelCatalog.defaultPostProcessingModel
        let autoPost = defaults.bool(forKey: DefaultsKey.autoPostProcess.rawValue)
        let batchModel = ModelCatalog.normalizedBatchTranscriptionModel(
            defaults.string(forKey: DefaultsKey.batchTranscriptionModel.rawValue)
        )
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
        self.batchTranscriptionModel = batchModel
        self.deepgramAPIKey = ""
        self.openRouterAPIKey = ""
        self.openAIAPIKey = ""
        self.elevenLabsAPIKey = ""
        self.cartesiaAPIKey = ""
        self.sonioxAPIKey = ""
        self.modulateAPIKey = ""
        self.assemblyAIAPIKey = ""
        self.gladiaAPIKey = ""
        self.googleAPIKey = ""
        self.xAIAPIKey = ""
        self.azureAPIKey = ""
        self.metaAPIKey = ""
        self.speechmaticsAPIKey = ""
        self.revAIAPIKey = ""
        self.mistralAPIKey = ""
        self.transcriptionKeywords = defaults.string(forKey: DefaultsKey.transcriptionKeywords.rawValue) ?? ""
        self.liveActivitiesEnabled = liveActivities
        self.visualDensity = density
        self.autoStartRecording = autoStart
        self.handsFreeDictationEnabled = handsFree
        self.preferredLocaleIdentifier = preferredLocale
        self.hardwareTriggerDestination = hardwareDest
        // An install that has never seen this setting gets the default window,
        // not the zero `double(forKey:)` returns for a missing key — which the
        // clamp would raise to the floor anyway, but reading it explicitly
        // keeps the stored value and the default from ever disagreeing.
        self.autoStopOnSilenceEnabled = defaults.bool(forKey: DefaultsKey.autoStopOnSilenceEnabled.rawValue)
        self.autoStopSilenceSeconds = CaptureEndPointingPolicy.silenceWindow(
            configured: defaults.object(forKey: DefaultsKey.autoStopSilenceSeconds.rawValue) as? TimeInterval
                ?? CaptureEndPointingPolicy.defaultSilenceWindowSeconds
        )
        self.postProcessingEnabled = postEnabled
        self.postProcessingModel = postModel
        self.autoPostProcess = autoPost

        // Load all API keys from the canonical secure storage, migrating any
        // values from legacy iOS keychain locations first. Default-provider
        // selection runs afterwards so it sees the loaded keys. Assigning each
        // @Published value re-persists it via didSet, which is harmless.
        // `didSet` never fires during init, so persist the seeded memory explicitly.
        selection.persist(to: defaults)
        defaults.set(
            self.rememberedRemoteTranscriptionMode.rawValue,
            forKey: DefaultsKey.rememberedRemoteTranscriptionMode.rawValue
        )

        guard loadsSecureStorage else { return }
        observeSecureStorageChanges()
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.ensureKeysLoaded()
            }
        }
        Task { @MainActor [weak self] in
            await self?.ensureKeysLoaded()
        }
    }

    private let defaults: UserDefaults

    /// Coalesces bootstrap and recording callers; a failed read remains retryable.
    /// Never use placeholder empty keys to make persistent provider decisions.
    @discardableResult
    public func ensureKeysLoaded() async -> Bool {
        if let keyLoadTask { return await keyLoadTask.value }
        if credentialsAvailable { return true }
        let task = Task { @MainActor in
            guard await self.credentials.preloadAndReportSuccess() else { return false }
            if self.migratesLegacyCredentials { await Self.migrateLegacyKeysIfNeeded() }
            guard await self.reloadSyncedAPIKeys() else { return false }
            self.configureDefaultProviderIfNeeded()
            return true
        }
        keyLoadTask = task
        let success = await task.value
        keyLoadTask = nil
        return success
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

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        if let keyChangeObserver {
            NotificationCenter.default.removeObserver(keyChangeObserver)
        }
    }

    /// Configure default transcription provider based on available API keys.
    /// Prefers Deepgram if API key is available, otherwise falls back to Apple Speech.
    private func configureDefaultProviderIfNeeded() {
        let isFirstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore.rawValue)
        let needsDeepgramKey = selectedModel.hasPrefix("deepgram") && !hasDeepgramKey

        // Note: ElevenLabs key is loaded async; its fallback is handled at recording time.
        if isFirstLaunch || needsDeepgramKey {
            if hasDeepgramKey {
                selectedModel = "deepgram/nova-3-streaming"
            } else {
                selectedModel = AppleLocalModels.preferredSpeechModelID
            }
            defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore.rawValue)
        }
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

    public var hasDeepgramKey: Bool { !deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasOpenRouterKey: Bool { !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasOpenAIKey: Bool { !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasElevenLabsKey: Bool { !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasCartesiaKey: Bool { !cartesiaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasSonioxKey: Bool { !sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasModulateKey: Bool { !modulateAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasAssemblyAIKey: Bool { !assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasGladiaKey: Bool { !gladiaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasGoogleKey: Bool { !googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasXAIKey: Bool { !xAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasAzureKey: Bool { !azureAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasMetaKey: Bool { !metaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasSpeechmaticsKey: Bool {
        !speechmaticsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var hasRevAIKey: Bool { !revAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasMistralKey: Bool { !mistralAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Identifiers currently available to model pickers. Because this is
    /// derived from the published key values, readiness badges refresh as soon
    /// as a key is saved, synced, or removed.
    public var storedAPIKeyIdentifiers: Set<String> {
        var identifiers: Set<String> = []
        if hasDeepgramKey { identifiers.insert(Self.deepgramKeyID) }
        if hasOpenRouterKey { identifiers.insert(Self.openRouterKeyID) }
        if hasOpenAIKey { identifiers.insert(Self.openAIKeyID) }
        if hasElevenLabsKey { identifiers.insert(Self.elevenLabsKeyID) }
        if hasCartesiaKey { identifiers.insert(Self.cartesiaKeyID) }
        if hasSonioxKey { identifiers.insert(Self.sonioxKeyID) }
        if hasModulateKey { identifiers.insert(Self.modulateKeyID) }
        if hasAssemblyAIKey { identifiers.insert(Self.assemblyAIKeyID) }
        if hasGladiaKey { identifiers.insert(Self.gladiaKeyID) }
        if hasGoogleKey { identifiers.insert(Self.googleKeyID) }
        if hasXAIKey { identifiers.insert(Self.xAIKeyID) }
        if hasAzureKey { identifiers.insert(Self.azureKeyID) }
        if hasMetaKey { identifiers.insert(Self.metaKeyID) }
        if hasSpeechmaticsKey { identifiers.insert(Self.speechmaticsKeyID) }
        if hasRevAIKey { identifiers.insert(Self.revAIKeyID) }
        if hasMistralKey { identifiers.insert(Self.mistralKeyID) }
        return identifiers
    }

    // Each credential is reloaded without overwriting a locked Keychain entry.
    @discardableResult
    public func reloadSyncedAPIKeys() async -> Bool {
        guard await credentials.preloadAndReportSuccess() else { return false }
        syncedKeyReloadDepth += 1
        defer { syncedKeyReloadDepth -= 1 }
        await reloadCoreAPIKeys()
        await reloadStreamingProviderAPIKeys()
        credentialsAvailable = true
        return true
    }

    private func reloadCoreAPIKeys() async {
        deepgramAPIKey = await syncedAPIKeyValue(
            identifier: Self.deepgramKeyID,
            currentValue: deepgramAPIKey
        )
        openRouterAPIKey = await syncedAPIKeyValue(
            identifier: Self.openRouterKeyID,
            currentValue: openRouterAPIKey
        )
        openAIAPIKey = await syncedAPIKeyValue(
            identifier: Self.openAIKeyID,
            currentValue: openAIAPIKey
        )
        elevenLabsAPIKey = await syncedAPIKeyValue(
            identifier: Self.elevenLabsKeyID,
            currentValue: elevenLabsAPIKey
        )
        cartesiaAPIKey = await syncedAPIKeyValue(
            identifier: Self.cartesiaKeyID,
            currentValue: cartesiaAPIKey
        )
        sonioxAPIKey = await syncedAPIKeyValue(
            identifier: Self.sonioxKeyID,
            currentValue: sonioxAPIKey
        )
        modulateAPIKey = await syncedAPIKeyValue(
            identifier: Self.modulateKeyID,
            currentValue: modulateAPIKey
        )
        assemblyAIAPIKey = await syncedAPIKeyValue(
            identifier: Self.assemblyAIKeyID,
            currentValue: assemblyAIAPIKey
        )
        gladiaAPIKey = await syncedAPIKeyValue(
            identifier: Self.gladiaKeyID,
            currentValue: gladiaAPIKey
        )
        googleAPIKey = await syncedAPIKeyValue(
            identifier: Self.googleKeyID,
            currentValue: googleAPIKey
        )
    }

    private func reloadStreamingProviderAPIKeys() async {
        xAIAPIKey = await syncedAPIKeyValue(
            identifier: Self.xAIKeyID,
            currentValue: xAIAPIKey
        )
        azureAPIKey = await syncedAPIKeyValue(
            identifier: Self.azureKeyID,
            currentValue: azureAPIKey
        )
        metaAPIKey = await syncedAPIKeyValue(
            identifier: Self.metaKeyID,
            currentValue: metaAPIKey
        )
        speechmaticsAPIKey = await syncedAPIKeyValue(
            identifier: Self.speechmaticsKeyID,
            currentValue: speechmaticsAPIKey
        )
        revAIAPIKey = await syncedAPIKeyValue(
            identifier: Self.revAIKeyID,
            currentValue: revAIAPIKey
        )
        mistralAPIKey = await syncedAPIKeyValue(
            identifier: Self.mistralKeyID,
            currentValue: mistralAPIKey
        )
    }

    @discardableResult
    public func syncCloudKitKeys() async -> Bool {
        let keySync = CloudKitKeySync.shared
        await keySync.configure(secureStorage: Self.credentialStorage)
        guard await keySync.isAvailable() else { return false }

        do {
            try await keySync.syncNow()
            await reloadSyncedAPIKeys()
            return true
        } catch {
            Self.logger.error("CloudKit API-key sync failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func syncedAPIKeyValue(identifier: String, currentValue: String) async -> String {
        do {
            return try await credentials.secret(identifier: identifier)
        } catch SecureStorageError.valueNotFound {
            return ""
        } catch {
            return currentValue
        }
    }

    private func observeSecureStorageChanges() {
        guard keyChangeObserver == nil else { return }
        keyChangeObserver = NotificationCenter.default.addObserver(
            forName: SecureStorage.didChangeSecretNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let identifier = notification.userInfo?[SecureStorage.NotificationUserInfoKey.identifier] as? String,
                  CloudKitKeySync.syncableIdentifiers.contains(identifier) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.reloadSyncedAPIKeys()
            }
        }
    }

    /// Returns the stored API key for a resolved live-transcription route, used
    /// by the generic shared-client recording path.
    public func liveAPIKey(for route: LiveTranscriptionRoute) -> String {
        guard let identifier = route.apiKeyIdentifier else { return "" }
        return liveAPIKeysByIdentifier[identifier] ?? ""
    }

    /// Every cloud live-transcription credential this app stores, keyed by the
    /// identifier `LiveTranscriptionRoute` resolves to. A table rather than a
    /// switch so adding a provider is one line and the lookup stays flat.
    private var liveAPIKeysByIdentifier: [String: String] {
        [
            Self.deepgramKeyID: deepgramAPIKey,
            Self.openAIKeyID: openAIAPIKey,
            Self.elevenLabsKeyID: elevenLabsAPIKey,
            Self.cartesiaKeyID: cartesiaAPIKey,
            Self.sonioxKeyID: sonioxAPIKey,
            Self.modulateKeyID: modulateAPIKey,
            Self.assemblyAIKeyID: assemblyAIAPIKey,
            Self.gladiaKeyID: gladiaAPIKey,
            Self.googleKeyID: googleAPIKey,
            Self.xAIKeyID: xAIAPIKey,
            Self.metaKeyID: metaAPIKey,
            Self.speechmaticsKeyID: speechmaticsAPIKey,
            Self.revAIKeyID: revAIAPIKey,
            Self.mistralKeyID: mistralAPIKey,
            Self.azureKeyID: azureAPIKey
        ]
    }

    public var batchAPIKey: String {
        batchAPIKey(for: batchTranscriptionModel)
    }

    /// Batch credentials resolve through the same canonical mapping the
    /// pickers and macOS use, so a directly-served model (OpenAI, Meta Muse,
    /// Gemini 3.5 Transcribe) never silently falls back to the OpenRouter key.
    /// Identifiers this app does not store keep the OpenRouter fallback, which
    /// is the route `IOSBatchTranscriber` takes for those models.
    public func batchAPIKey(for modelIdentifier: String) -> String {
        switch ModelCredentialResolver.requirement(
            for: modelIdentifier, purpose: .batchTranscription
        ) {
        case .notRequired:
            return ""
        case .apiKey(let identifier, _):
            return apiKeysByIdentifier[identifier] ?? openRouterAPIKey
        }
    }

    /// Every stored transcription credential keyed by its canonical
    /// identifier, so credential lookups stay a table rather than a switch.
    private var apiKeysByIdentifier: [String: String] {
        var keys = liveAPIKeysByIdentifier
        keys[Self.openRouterKeyID] = openRouterAPIKey
        return keys
    }

    public static let openAIBatchModelIDs = OpenAITranscriptionModels.directBatchModelIDs

    /// Remote streaming models with an implemented iOS recording path. Shared
    /// catalogue entries that remain macOS-only are omitted rather than shown
    /// disabled or silently routed to a different provider.
    public static let supportedLiveModels: [ModelCatalog.Option] =
        ModelCatalog.remoteLiveTranscription.filter { option in
            LiveTranscriptionRouting.route(for: option.id)?.isSupportedOnIOS == true
        }

    /// iOS currently supports OpenAI's transcription endpoint and OpenRouter's
    /// audio-capable batch models. Other catalogue entries remain shared with
    /// Mac but are hidden until their upload clients are available on iPhone.
    public static let supportedBatchModels: [ModelCatalog.Option] =
        ModelCatalog.batchTranscription.filter { option in
            AppleLocalModels.isSpeechAnalyzerModel(option.id)
                || openAIBatchModelIDs.contains(option.id)
                || AzureTranscriptionModels.batchIDs.contains(option.id)
                // OpenRouter-routed Gemini 2.x batch models upload through the
                // OpenRouter client; Gemini 3.5 Transcribe uploads through the
                // shared `GeminiInteractionsClient` with the Google key
                // (issue #862). Both are listed, and `batchAPIKey(for:)` and
                // `IOSBatchTranscriptionRoute` keep them on separate paths.
                || option.id.hasPrefix("google/")
                || option.id == "openai/gpt-4o-audio-preview-2024-12-17"
                || option.id == MetaMuseVoiceTranscribe.batchCatalogID
                || option.id == CartesiaBatchClient.catalogID
                // xAI's dedicated speech-to-text endpoint uploads through the
                // shared `XAIBatchTranscriptionClient` with the xAI key.
                || option.id == XAISpeechToText.batchCatalogID
                // Gladia's pre-recorded job API uploads through the shared
                // `GladiaBatchClient` with the `gladia.apiKey` this app already
                // stores for live Solaria. Speechmatics batch stays macOS-only
                // for now: iOS has no Speechmatics credential field, and a
                // model that can never resolve a key is hidden rather than
                // shown failing (see Docs/batch-transcription-providers.md).
                || option.id == GladiaBatchClient.catalogID
        }

    // MARK: - Legacy migration

    /// One-time migration of API keys from the pre-unification iOS keychain
    /// locations (raw per-account items and the old ElevenLabs SecureStorage,
    /// both under service `com.speak.ios.credentials`) into the canonical,
    /// iCloud-syncable store. Additive and idempotent: legacy items are read but
    /// never deleted, and each key is only migrated when the new store lacks it.
    private static func migrateLegacyKeysIfNeeded() async {
        guard ReleaseTrain.current == .stable else { return }
        let existing = Set(await credentialStorage.knownIdentifiers())

        for identifier in [deepgramKeyID, openRouterKeyID, openAIKeyID] where !existing.contains(identifier) {
            if let legacy = legacyRawSecret(account: identifier), !legacy.isEmpty {
                try? await credentialStorage.storeSecret(legacy, identifier: identifier)
            }
        }

        if !existing.contains(elevenLabsKeyID) {
            let legacyStore = SecureStorage(
                configuration: SecureStorageConfiguration(service: "com.speak.ios.credentials")
            )
            if let key = try? await legacyStore.secret(identifier: elevenLabsKeyID), !key.isEmpty {
                try? await credentialStorage.storeSecret(key, identifier: elevenLabsKeyID)
            }
        }
    }

    /// Reads a value from the legacy raw per-account keychain items.
    private static func legacyRawSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.speak.ios.credentials",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }
}

enum IOSTranscriptionLocation: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

#endif
