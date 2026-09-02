#if os(iOS)
import SwiftUI
import SpeakCore
import SpeakSync
import Security
import OSLog

// swiftlint:disable file_length

// MARK: - Hardware Trigger Destination

/// What happens to the transcript after a hardware-triggered recording stops.
///
/// Used by every "headless" entry point: Action Button (iPhone 15 Pro+),
/// Siri voice commands, the Shortcuts app, Lock Screen / Home Screen widget,
/// Control Center, Back Tap. The main in-app record-and-stop flow is
/// unaffected — it always shows the result on screen.
public enum HardwareTriggerDestination: String, CaseIterable, Identifiable, Sendable {
    /// Copy the transcript to the clipboard. Default — matches behaviour
    /// prior to the destination setting being added.
    case clipboard

    /// Copy to clipboard and run the configured post-processor (OpenRouter)
    /// in the background, replacing the clipboard with the polished version
    /// when it lands. Falls back to plain `.clipboard` if no OpenRouter key.
    case clipboardAndPostProcess

    /// Save to history only — don't touch the clipboard, don't post-process.
    /// Useful if the user wants to capture a thought without polluting the
    /// pasteboard with something they didn't choose to paste.
    case historyOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clipboard: return "Copy to Clipboard"
        case .clipboardAndPostProcess: return "Copy & Polish"
        case .historyOnly: return "Save to History Only"
        }
    }

    public var summary: String {
        switch self {
        case .clipboard:
            return "Transcript is copied to the clipboard immediately when recording stops."
        case .clipboardAndPostProcess:
            return "Transcript is copied to the clipboard, then re-cleaned with your post-processing model "
                + "and the polished version is re-copied."
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
    public static let shared = AppSettings()

    @Published public var selectedModel: String {
        didSet {
            defaults.set(selectedModel, forKey: "selectedModel")
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
            defaults.set(transcriptionMode.rawValue, forKey: "transcriptionMode")
            publishKeyboardProfileSelection()
        }
    }

    /// The remote sub-mode the user last chose, remembered while they are in
    /// local mode so returning to remote restores streaming or batch.
    @Published public var rememberedRemoteTranscriptionMode: IOSTranscriptionMode {
        didSet { defaults.set(rememberedRemoteTranscriptionMode.rawValue, forKey: Self.rememberedRemoteModeKey) }
    }

    static let rememberedRemoteModeKey = "rememberedRemoteTranscriptionMode"

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
                defaults.set(batchTranscriptionModel, forKey: "batchTranscriptionModel")
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

    @Published public var xAIAPIKey: String {
        didSet { persistSecret(xAIAPIKey, identifier: Self.xAIKeyID) }
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
    static let xAIKeyID = "xai.apiKey"

    private static let credentialStorage = SecureStorage(
        configuration: SecureStorageConfiguration(
            service: "com.github.speakapp.credentials",
            masterAccount: "speak-app-secrets",
            legacyServices: ["com.justspeaktoit.credentials"]
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
    /// The async keychain load kicked off by `init`. `ensureKeysLoaded()`
    /// awaits it so cold-start callers never read the placeholder empty keys.
    private var initialKeyLoadTask: Task<Void, Never>?

    /// Persists (or clears when empty) an API key on the canonical secure store.
    /// Keychain failures are logged rather than silently dropped so a key that
    /// appears saved but didn't persist is diagnosable from logs.
    private func persistSecret(_ value: String, identifier: String) {
        guard syncedKeyReloadDepth == 0 else { return }
        Task {
            do {
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await Self.credentialStorage.removeSecret(identifier: identifier)
                } else {
                    try await Self.credentialStorage.storeSecret(value, identifier: identifier)
                }
            } catch {
                Self.logger.error(
                    "Failed to persist secret \(identifier, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    @Published public var liveActivitiesEnabled: Bool {
        didSet { defaults.set(liveActivitiesEnabled, forKey: "liveActivitiesEnabled") }
    }

    @Published public var visualDensity: AppVisualDensity {
        didSet { defaults.set(visualDensity.rawValue, forKey: "visualDensity") }
    }

    @Published public var autoStartRecording: Bool {
        didSet { defaults.set(autoStartRecording, forKey: "autoStartRecording") }
    }

    /// Hands-free dictation: recording is driven by Apple's on-device speech
    /// detector rather than the record button. Off by default, and inert below
    /// iOS 26 where `SpeechDetector` does not exist. The defaults key matches
    /// macOS so the two platforms stay in step.
    @Published public var handsFreeDictationEnabled: Bool {
        didSet {
            defaults.set(handsFreeDictationEnabled, forKey: "handsFreeDictationEnabled")
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
            defaults.set(preferredLocaleIdentifier, forKey: "preferredLocale")
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
            defaults.set(hardwareTriggerDestination.rawValue, forKey: "hardwareTriggerDestination")
        }
    }

    // MARK: - Post-Processing Settings

    @Published public var postProcessingEnabled: Bool {
        didSet {
            defaults.set(postProcessingEnabled, forKey: "postProcessingEnabled")
            publishKeyboardProfileSelection()
        }
    }

    @Published public var postProcessingModel: String {
        didSet {
            defaults.set(postProcessingModel, forKey: "postProcessingModel")
            publishKeyboardProfileSelection()
        }
    }

    @Published public var autoPostProcess: Bool {
        didSet { defaults.set(autoPostProcess, forKey: "autoPostProcess") }
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
        loadsSecureStorage: Bool = true
    ) {
        self.defaults = defaults
        let storedSelectedRaw = defaults.string(forKey: "selectedModel")
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
        let liveActivities = defaults.object(forKey: "liveActivitiesEnabled") as? Bool ?? true
        let density = AppVisualDensity(
            rawValue: defaults.string(forKey: "visualDensity") ?? ""
        ) ?? .normal
        let autoStart = defaults.bool(forKey: "autoStartRecording")
        let handsFree = defaults.bool(forKey: "handsFreeDictationEnabled")
        let preferredLocale = TranscriptionLanguageCatalog.normalizedIdentifier(
            defaults.string(forKey: "preferredLocale")
        )

        // Hardware trigger destination (Action Button, Siri, Shortcuts).
        // Default to .clipboard for backwards compatibility with prior versions.
        let hardwareDestRaw = defaults.string(forKey: "hardwareTriggerDestination")
        let hardwareDest = HardwareTriggerDestination(rawValue: hardwareDestRaw ?? "") ?? .clipboard

        // Post-processing settings
        let postEnabled = defaults.bool(forKey: "postProcessingEnabled")
        let storedPostModel = defaults.string(forKey: "postProcessingModel")
        let normalizedPostModel = ModelCatalog.normalizedPostProcessingModel(storedPostModel)
        let postModel = Self.postProcessingModels.contains { $0.id == normalizedPostModel }
            ? normalizedPostModel
            : ModelCatalog.defaultPostProcessingModel
        let autoPost = defaults.bool(forKey: "autoPostProcess")
        let batchModel = ModelCatalog.normalizedBatchTranscriptionModel(
            defaults.string(forKey: "batchTranscriptionModel")
        )
        let mode = IOSTranscriptionMode(
            rawValue: defaults.string(forKey: "transcriptionMode") ?? ""
        ) ?? .streaming

        var selection = LiveTranscriptionSelection(defaults: defaults)
        // Existing installs upgrade with their active model remembered for the
        // placement it belongs to; the other placement stays empty until chosen.
        selection.rememberIfMissing(selected)
        self.liveTranscriptionSelection = selection
        self.rememberedRemoteTranscriptionMode = IOSTranscriptionMode(
            rawValue: defaults.string(forKey: Self.rememberedRemoteModeKey) ?? ""
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
        self.xAIAPIKey = ""
        self.liveActivitiesEnabled = liveActivities
        self.visualDensity = density
        self.autoStartRecording = autoStart
        self.handsFreeDictationEnabled = handsFree
        self.preferredLocaleIdentifier = preferredLocale
        self.hardwareTriggerDestination = hardwareDest
        self.postProcessingEnabled = postEnabled
        self.postProcessingModel = postModel
        self.autoPostProcess = autoPost

        // Load all API keys from the canonical secure storage, migrating any
        // values from legacy iOS keychain locations first. Default-provider
        // selection runs afterwards so it sees the loaded keys. Assigning each
        // @Published value re-persists it via didSet, which is harmless.
        // `didSet` never fires during init, so persist the seeded memory explicitly.
        selection.persist(to: defaults)
        defaults.set(self.rememberedRemoteTranscriptionMode.rawValue, forKey: Self.rememberedRemoteModeKey)

        guard loadsSecureStorage else { return }
        initialKeyLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Self.migrateLegacyKeysIfNeeded()
            await self.reloadSyncedAPIKeys()
            self.observeSecureStorageChanges()
            self.configureDefaultProviderIfNeeded()
        }
    }

    private let defaults: UserDefaults

    /// Waits until the initial keychain load kicked off by `init` has finished.
    /// Idempotent and cheap once loaded. Recording paths await this before
    /// reading API keys so a cold launch (e.g. from the Action Button) doesn't
    /// see the placeholder empty keys and silently fall back to Apple Speech.
    public func ensureKeysLoaded() async {
        await initialKeyLoadTask?.value
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
        if let keyChangeObserver {
            NotificationCenter.default.removeObserver(keyChangeObserver)
        }
    }

    /// Configure default transcription provider based on available API keys.
    /// Prefers Deepgram if API key is available, otherwise falls back to Apple Speech.
    private func configureDefaultProviderIfNeeded() {
        let isFirstLaunch = !defaults.bool(forKey: "hasLaunchedBefore")
        let needsDeepgramKey = selectedModel.hasPrefix("deepgram") && !hasDeepgramKey

        // Note: ElevenLabs key is loaded async; its fallback is handled at recording time.
        if isFirstLaunch || needsDeepgramKey {
            if hasDeepgramKey {
                selectedModel = "deepgram/nova-3-streaming"
            } else {
                selectedModel = AppleLocalModels.preferredSpeechModelID
            }
            defaults.set(true, forKey: "hasLaunchedBefore")
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
    public var hasXAIKey: Bool { !xAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        if hasXAIKey { identifiers.insert(Self.xAIKeyID) }
        return identifiers
    }

    public func reloadSyncedAPIKeys() async {
        syncedKeyReloadDepth += 1
        defer { syncedKeyReloadDepth -= 1 }
        deepgramAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.deepgramKeyID,
            currentValue: deepgramAPIKey
        )
        openRouterAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.openRouterKeyID,
            currentValue: openRouterAPIKey
        )
        openAIAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.openAIKeyID,
            currentValue: openAIAPIKey
        )
        elevenLabsAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.elevenLabsKeyID,
            currentValue: elevenLabsAPIKey
        )
        cartesiaAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.cartesiaKeyID,
            currentValue: cartesiaAPIKey
        )
        sonioxAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.sonioxKeyID,
            currentValue: sonioxAPIKey
        )
        modulateAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.modulateKeyID,
            currentValue: modulateAPIKey
        )
        assemblyAIAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.assemblyAIKeyID,
            currentValue: assemblyAIAPIKey
        )
        gladiaAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.gladiaKeyID,
            currentValue: gladiaAPIKey
        )
        xAIAPIKey = await Self.syncedAPIKeyValue(
            identifier: Self.xAIKeyID,
            currentValue: xAIAPIKey
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

    private static func syncedAPIKeyValue(identifier: String, currentValue: String) async -> String {
        do {
            return try await credentialStorage.secret(identifier: identifier)
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
        switch route.apiKeyIdentifier {
        case Self.deepgramKeyID: return deepgramAPIKey
        case Self.openAIKeyID: return openAIAPIKey
        case Self.elevenLabsKeyID: return elevenLabsAPIKey
        case Self.cartesiaKeyID: return cartesiaAPIKey
        case Self.sonioxKeyID: return sonioxAPIKey
        case Self.modulateKeyID: return modulateAPIKey
        case Self.assemblyAIKeyID: return assemblyAIAPIKey
        case Self.gladiaKeyID: return gladiaAPIKey
        case Self.xAIKeyID: return xAIAPIKey
        default: return ""
        }
    }

    public var batchAPIKey: String {
        batchAPIKey(for: batchTranscriptionModel)
    }

    public func batchAPIKey(for modelIdentifier: String) -> String {
        if AppleLocalModels.isSpeechAnalyzerModel(modelIdentifier) {
            return ""
        }
        if Self.openAIBatchModelIDs.contains(modelIdentifier) {
            return openAIAPIKey
        }
        return openRouterAPIKey
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
                || option.id.hasPrefix("google/")
                || option.id == "openai/gpt-4o-audio-preview-2024-12-17"
        }

    // MARK: - Legacy migration

    /// One-time migration of API keys from the pre-unification iOS keychain
    /// locations (raw per-account items and the old ElevenLabs SecureStorage,
    /// both under service `com.speak.ios.credentials`) into the canonical,
    /// iCloud-syncable store. Additive and idempotent: legacy items are read but
    /// never deleted, and each key is only migrated when the new store lacks it.
    private static func migrateLegacyKeysIfNeeded() async {
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

// MARK: - Settings View

/// A provider-titled group of live-transcription models, so the picker can list
/// a growing catalogue in tidy per-provider sections instead of one long list.
private struct LiveModelGroup: Identifiable {
    let id: String
    let title: String
    let options: [ModelCatalog.Option]

    /// Buckets catalogue options by provider, preserving first-appearance order
    /// so the sections stay stable as models are added. Options whose id doesn't
    /// resolve to a known provider are still shown (grouped by their id prefix)
    /// rather than silently dropped.
    static func grouped(_ options: [ModelCatalog.Option]) -> [LiveModelGroup] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [ModelCatalog.Option]] = [:]
        for option in options {
            let route = LiveTranscriptionRouting.route(for: option.id)
            let key = route?.provider.rawValue ?? String(option.id.prefix { $0 != "/" })
            if buckets[key] == nil {
                order.append(key)
                titles[key] = route?.provider.displayName ?? key.capitalized
            }
            buckets[key, default: []].append(option)
        }
        return order.map { LiveModelGroup(id: $0, title: titles[$0] ?? $0, options: buckets[$0] ?? []) }
    }
}

private struct BatchModelGroup: Identifiable {
    let id: String
    let title: String
    let options: [ModelCatalog.Option]

    static func grouped(_ options: [ModelCatalog.Option]) -> [BatchModelGroup] {
        let grouped = Dictionary(grouping: options) { option in
            String(option.id.prefix { $0 != "/" })
        }
        return grouped.keys.sorted().map { provider in
            BatchModelGroup(
                id: provider,
                title: providerDisplayName(provider),
                options: grouped[provider, default: []]
            )
        }
    }

    private static func providerDisplayName(_ provider: String) -> String {
        let names = [
            "openai": "OpenAI",
            "groq": "Groq",
            "revai": "Rev.ai",
            "mistral": "Mistral",
            "soniox": "Soniox",
            "deepgram": "Deepgram",
            "assemblyai": "AssemblyAI",
            "elevenlabs": "ElevenLabs",
            "modulate": "Modulate",
            "google": "Google via OpenRouter"
        ]
        return names[provider] ?? provider.capitalized
    }
}

enum IOSTranscriptionLocation: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// swiftlint:disable:next type_body_length
public struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.openClawEnabled) private var openClawEnabled
    @Environment(\.iOSKeyboardEnabled) private var iOSKeyboardEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingAPIKeys = false
    @State private var missingTranscriptionAPIKeyAlert: IOSMissingTranscriptionAPIKeyAlert?

    public init() {}

    public var body: some View {
        Form {
            Section("Appearance") {
                Picker("Layout Density", selection: $settings.visualDensity) {
                    ForEach(AppVisualDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)

                if !usesInlineDensityLayout {
                    Text(
                        "Compact restructures screens around inline controls, shorter cards, "
                            + "and grouped status rows while keeping controls easy to tap."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Language") {
                Picker("Spoken Language", selection: $settings.preferredLocaleIdentifier) {
                    ForEach(TranscriptionLanguageCatalog.options) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("spokenLanguagePicker")

                if !usesInlineDensityLayout {
                    Text(
                        "Automatic lets remote providers detect the language. "
                            + "Apple on-device transcription uses your current system locale."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Transcription") {
                Picker("Where transcription runs", selection: transcriptionLocationBinding) {
                    ForEach(IOSTranscriptionLocation.allCases) { location in
                        Text(location.displayName).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("transcriptionLocationPicker")

                if transcriptionLocationBinding.wrappedValue == .local {
                    Picker("Apple On-Device Model", selection: selectedModelBinding) {
                        ForEach(ModelCatalog.onDeviceLiveTranscription) { option in
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                IOSModelCredentialStatusView(
                                    availability: ModelCredentialResolver.availability(
                                        for: option.id,
                                        purpose: .liveTranscription,
                                        storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                    )
                                )
                            }
                            .accessibilityElement(children: .combine)
                            .tag(option.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("appleOnDeviceModelPicker")

                    if !usesInlineDensityLayout {
                        Text("Uses Apple's built-in speech engine. Audio stays on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Remote Mode", selection: remoteTranscriptionModeBinding) {
                        ForEach(IOSTranscriptionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("remoteTranscriptionModePicker")

                    if settings.transcriptionMode == .streaming {
                        Picker("Remote Streaming Model", selection: selectedModelBinding) {
                            ForEach(LiveModelGroup.grouped(AppSettings.supportedLiveModels)) { group in
                                Section(group.title) {
                                    ForEach(group.options) { option in
                                        HStack {
                                            Text(option.displayName)
                                            Spacer()
                                            IOSModelCredentialStatusView(
                                                availability: ModelCredentialResolver.availability(
                                                    for: option.id,
                                                    purpose: .liveTranscription,
                                                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                                )
                                            )
                                        }
                                        .accessibilityElement(children: .combine)
                                        .tag(option.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("remoteStreamingModelPicker")
                    } else {
                        Picker("Remote Batch Model", selection: $settings.batchTranscriptionModel) {
                            ForEach(BatchModelGroup.grouped(AppSettings.supportedBatchModels)) { group in
                                Section(group.title) {
                                    ForEach(group.options) { option in
                                        HStack {
                                            Text(ModelCatalog.friendlyName(for: option.id))
                                            Spacer()
                                            IOSModelCredentialStatusView(
                                                availability: ModelCredentialResolver.availability(
                                                    for: option.id,
                                                    purpose: .batchTranscription,
                                                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                                )
                                            )
                                        }
                                        .accessibilityElement(children: .combine)
                                        .tag(option.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("remoteBatchModelPicker")
                    }

                    if !usesInlineDensityLayout {
                        Text(settings.transcriptionMode == .streaming
                            ? "Text appears while audio is streamed to the selected provider."
                            : "Audio is uploaded after recording for a more complete transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if transcriptionLocationBinding.wrappedValue == .remote,
                   settings.transcriptionMode == .streaming,
                   let route = LiveTranscriptionRouting.route(for: settings.selectedModel),
                   route.isSupportedOnIOS,
                   route.apiKeyIdentifier != nil,
                   settings.liveAPIKey(for: route).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(
                        "Add this provider's API key below to use this model.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }

                if transcriptionLocationBinding.wrappedValue == .remote,
                   settings.transcriptionMode == .batch,
                   !AppleLocalModels.isSpeechAnalyzerModel(settings.batchTranscriptionModel),
                   settings.batchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(
                        AppSettings.openAIBatchModelIDs.contains(settings.batchTranscriptionModel)
                            ? "Add an OpenAI API key below to use this model."
                            : "Add an OpenRouter API key below to use this model.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }

            }

            Section("Behavior") {
                Toggle(isOn: $settings.autoStartRecording) {
                    Label("Auto-Start Recording", systemImage: "mic.badge.plus")
                }

                if settings.autoStartRecording && !usesInlineDensityLayout {
                    Text("Recording starts automatically when you open the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.handsFreeDictationEnabled) {
                    Label("Hands-Free Dictation", systemImage: "waveform.badge.mic")
                }
                .disabled(!settings.handsFreeDictationSupported)
                .accessibilityIdentifier("handsFreeDictationToggle")

                if !usesInlineDensityLayout {
                    Text(handsFreeDictationCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.liveActivitiesEnabled) {
                    Label("Live Activities", systemImage: "platter.filled.bottom.iphone")
                }

                if settings.liveActivitiesEnabled && !usesInlineDensityLayout {
                    Text("Shows transcription progress on Lock Screen and Dynamic Island.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if iOSKeyboardEnabled {
                Section("Just Speak Keyboard") {
                    NavigationLink {
                        KeyboardSetupView()
                    } label: {
                        HStack {
                            Label("Set Up Keyboard", systemImage: "keyboard")
                            Spacer()
                            Text(keyboardStatusLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("keyboardSetupLink")

                    if !usesInlineDensityLayout {
                        Text("Transcribe into other apps through a private handoff to Just Speak.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Hardware Trigger") {
                NavigationLink {
                    HardwareTriggerSettingsView(settings: settings)
                } label: {
                    HStack {
                        Label("Action Button & Shortcuts", systemImage: "button.programmable")
                        Spacer()
                        Text(settings.hardwareTriggerDestination.displayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("hardwareTriggerSettingsLink")

                if !usesInlineDensityLayout {
                    Text(
                        "Trigger transcription from the Action Button, Siri, Lock Screen, "
                            + "Control Center, or Back Tap."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Post-Processing") {
                Toggle(isOn: $settings.autoPostProcess) {
                    Label("Auto-Polish After Recording", systemImage: "wand.and.stars")
                }

                if settings.autoPostProcess && !usesInlineDensityLayout {
                    Text("Automatically opens polish view after each recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    PostProcessingSettingsView(settings: settings)
                } label: {
                    HStack {
                        Label("Model & Prompt", systemImage: "slider.horizontal.3")
                        Spacer()
                        Text(postProcessingModelName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !settings.hasOpenRouterKey {
                    Label("OpenRouter API key required", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("API Keys") {
                if usesInlineDensityLayout {
                    NavigationLink {
                        APIKeysView(settings: settings)
                    } label: {
                        compactAPIKeySummary
                    }
                } else {
                    apiKeyStatusRow(
                        name: "Deepgram",
                        systemImage: "waveform",
                        isStored: settings.hasDeepgramKey
                    )
                    apiKeyStatusRow(
                        name: "ElevenLabs",
                        systemImage: "mic.and.signal.meter",
                        isStored: settings.hasElevenLabsKey
                    )
                    apiKeyStatusRow(
                        name: "OpenRouter",
                        systemImage: "network",
                        isStored: settings.hasOpenRouterKey
                    )
                    apiKeyStatusRow(
                        name: "OpenAI",
                        systemImage: "brain.head.profile",
                        isStored: settings.hasOpenAIKey
                    )

                    NavigationLink {
                        APIKeysView(settings: settings)
                    } label: {
                        Label("Manage Keys", systemImage: "key.viewfinder")
                    }
                }
            }

            Section("Sync") {
                // CloudKit History Sync
                CloudKitSyncSettingsSection()

                CloudKitKeySyncSettingsSection()

                // Sync status
                let syncStatus = SyncStatus.current(
                    iCloudCloudKitAvailable: HistorySyncEngine.shared.state.isCloudAvailable
                )

                if usesInlineDensityLayout {
                    compactSyncStatus(syncStatus)
                } else {
                    syncStatusRows(syncStatus)
                }

                if let lastSync = syncStatus.lastSyncDate {
                    LabeledContent("Last Sync") {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                // QR Transfer options
                NavigationLink {
                    QRCodeGeneratorView()
                } label: {
                    Label("Share to Another Device", systemImage: "qrcode")
                }

                NavigationLink {
                    QRCodeScannerView()
                } label: {
                    Label("Import from QR Code", systemImage: "qrcode.viewfinder")
                }

                if !usesInlineDensityLayout {
                    Text("Just Speak to It uses iCloud for settings and history when available. "
                        + "If iCloud is unavailable, Bonjour Transport can send sessions to a paired Mac "
                        + "on your local network; QR transfer remains available for manual setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if openClawEnabled {
                Section("OpenClaw") {
                    NavigationLink {
                        OpenClawSettingsView()
                    } label: {
                        Label("Configure OpenClaw", systemImage: "bolt.horizontal.icloud")
                    }

                    if OpenClawSettings.shared.isConfigured {
                        Label("Connected", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Recordings") {
                NavigationLink {
                    RecordingsView()
                } label: {
                    Label("Saved Recordings", systemImage: "waveform.circle")
                }

                if !usesInlineDensityLayout {
                    Text(
                        "Audio is saved locally during transcription so you can "
                            + "replay or re-transcribe if connectivity was lost."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Send to Mac") {
                NavigationLink {
                    SendToMacView()
                } label: {
                    Label("Configure Mac Connection", systemImage: "desktopcomputer")
                }
            }

            Section("Privacy & Debugging") {
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy Information", systemImage: "hand.raised")
                }

                Toggle(isOn: Binding(
                    get: { SpeakLogger.isDebugMode },
                    set: { SpeakLogger.isDebugMode = $0 }
                )) {
                    Label("Debug Logging", systemImage: "ant")
                }

                if SpeakLogger.isDebugMode && !usesInlineDensityLayout {
                    Text("Debug mode logs additional details for troubleshooting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                if usesInlineDensityLayout {
                    compactBuildSummary
                } else {
                    LabeledContent("Version") {
                        Text("\(appVersion) (\(appBuild))")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Commit") {
                        Text(BuildInfo.gitCommitShort)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }

                    LabeledContent("SpeakCore") {
                        Text(SpeakCore.version)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    ReleaseNotesView()
                } label: {
                    Label("Release Notes", systemImage: "sparkles")
                }
                .accessibilityHint("Shows what changed in this version and earlier versions")
            }
        }
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .listSectionSpacing(settings.visualDensity.listSectionSpacing)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(usesInlineDensityLayout ? .inline : .automatic)
        .controlSize(settings.visualDensity.isCompact ? .small : .regular)
        .navigationDestination(isPresented: $showingAPIKeys) {
            APIKeysView(settings: settings)
        }
        .iosMissingTranscriptionAPIKeyAlert(
            alert: $missingTranscriptionAPIKeyAlert,
            showingAPIKeys: $showingAPIKeys,
            openURL: openURL
        )
    }

    private var batchModeDescription: String {
        if AppleLocalModels.isSpeechAnalyzerModel(settings.batchTranscriptionModel) {
            return "Audio is recorded first, then transcribed privately on this device when you stop."
        }
        return "Audio is recorded first, then uploaded when you stop for a more complete transcript."
    }

    private var postProcessingModelName: String {
        ModelCatalog.friendlyName(for: settings.postProcessingModel)
    }

    private var usesInlineDensityLayout: Bool {
        settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
    }

    /// Silence budget is read from the shared policy so the copy cannot drift
    /// from the behaviour, and matches the macOS wording.
    private var handsFreeDictationCaption: String {
        guard settings.handsFreeDictationSupported else {
            return "Requires iOS 26 or later — Apple's on-device speech detector isn't available here."
        }
        return "Arm from the microphone button. The microphone remains active while armed; "
            + "silent audio stays in memory only and is never stored or sent off-device."
    }

    private var keyboardStatusLabel: String {
        guard let observation = KeyboardHandoffStore.shared.extensionObservation() else {
            return "Not observed"
        }
        return observation.hadFullAccess ? "Full Access on" : "Full Access off"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var compactBuildSummary: some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label("\(appVersion) (\(appBuild))", systemImage: "app.badge")
            Spacer()
            Text(BuildInfo.gitCommitShort)
                .font(.caption.monospaced())
            Text("Core \(SpeakCore.version)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var compactAPIKeySummary: some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label("Manage Keys", systemImage: "key.viewfinder")
            Spacer()
            Text("\(storedAPIKeyCount)/\(managedAPIKeyCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(storedAPIKeyCount == managedAPIKeyCount ? .green : .secondary)
        }
        .accessibilityLabel(
            "\(storedAPIKeyCount) of \(managedAPIKeyCount) API keys stored. Manage keys."
        )
    }

    private var storedAPIKeyCount: Int {
        managedAPIKeyEntries.filter(\.isStored).count
    }

    private var managedAPIKeyCount: Int {
        managedAPIKeyEntries.count
    }

    private var managedAPIKeyEntries: [APIKeyListEntry] {
        APIKeysView.entries(for: settings)
    }

    private func apiKeyStatusRow(name: String, systemImage: String, isStored: Bool) -> some View {
        HStack {
            Label(name, systemImage: systemImage)
                .accessibilityLabel("\(name) API Key")
            Spacer()
            Text(isStored ? "Stored" : "Missing")
                .foregroundStyle(isStored ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func compactSyncStatus(_ status: SyncStatus) -> some View {
        HStack(spacing: settings.visualDensity.inlineSpacing) {
            Label(status.preferredBackend.displayName, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
            Spacer()
            syncAvailabilityIcon(
                "key.icloud",
                available: status.iCloudKeychainAvailable,
                label: "iCloud Keychain"
            )
            syncAvailabilityIcon(
                "icloud",
                available: status.iCloudKVStoreAvailable,
                label: "iCloud Settings"
            )
            syncAvailabilityIcon(
                "network",
                available: status.transportAvailable,
                label: "Bonjour Transport"
            )
        }
        .font(.caption)
    }

    private func syncAvailabilityIcon(
        _ systemImage: String,
        available: Bool,
        label: String
    ) -> some View {
        Image(systemName: available ? systemImage : "xmark.circle")
            .foregroundStyle(available ? .green : .secondary)
            .accessibilityLabel("\(label): \(available ? "available" : "unavailable")")
    }

    private func syncStatusRows(_ status: SyncStatus) -> some View {
        Group {
            HStack {
                Label("Preferred Sync", systemImage: "arrow.triangle.branch")
                Spacer()
                Text(status.preferredBackend.displayName)
                    .foregroundStyle(status.preferredBackend != .localOnly ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            syncStatusRow(
                name: "iCloud Keychain",
                systemImage: "key.icloud",
                value: status.iCloudKeychainAvailable ? "Available" : "Local only",
                isAvailable: status.iCloudKeychainAvailable
            )
            syncStatusRow(
                name: "iCloud Settings",
                systemImage: "icloud",
                value: status.iCloudKVStoreAvailable ? "Available" : "Local only",
                isAvailable: status.iCloudKVStoreAvailable
            )
            syncStatusRow(
                name: "Bonjour Transport",
                systemImage: "network",
                value: status.transportAvailable ? "Ready" : "Unavailable",
                isAvailable: status.transportAvailable
            )
        }
    }

    private func syncStatusRow(
        name: String,
        systemImage: String,
        value: String,
        isAvailable: Bool
    ) -> some View {
        HStack {
            Label(name, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(isAvailable ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hardware Trigger Settings View

/// Configuration screen for the Action Button / Shortcuts / Siri / widget
/// recording entry points. Lets the user pick what happens to the transcript
/// when recording stops and explains how to wire each entry point.
struct HardwareTriggerSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("When Recording Stops") {
                Picker("Destination", selection: $settings.hardwareTriggerDestination) {
                    ForEach(HardwareTriggerDestination.allCases) { destination in
                        Text(destination.displayName)
                            .accessibilityIdentifier("hardwareTriggerDestination.\(destination.rawValue)")
                            .tag(destination)
                    }
                }
                .accessibilityIdentifier("hardwareTriggerDestinationPicker")
                .pickerStyle(.inline)
                .labelsHidden()

                Text(settings.hardwareTriggerDestination.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.hardwareTriggerDestination == .clipboardAndPostProcess
                    && !settings.hasOpenRouterKey {
                    Label(
                        "Add an OpenRouter API key under API Keys to enable polishing. "
                            + "Without it, polishing falls back to plain clipboard.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Set Up the Action Button") {
                Text(
                    "On iPhone 15 Pro and later you can map the Action Button to start recording in one press — "
                        + "even from the Lock Screen."
                )
                    .font(.callout)

                StepRow(number: 1, text: "Open the Shortcuts app and tap the + button.")
                StepRow(
                    number: 2,
                    text: "Search for JustSpeakToIt and choose Toggle Recording for a single-button flow. "
                        + "Do not add a separate Copy to Clipboard action — JustSpeakToIt copies the transcript "
                        + "when you stop. Use Start Recording only if you also create a separate Stop Recording "
                        + "shortcut."
                )
                StepRow(number: 3, text: "Name the shortcut and tap Done.")
                StepRow(
                    number: 4,
                    text: "Open Settings → Action Button, swipe to Shortcut, and pick the shortcut you just made."
                )

                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Shortcuts App", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("openShortcutsAppButton")
            }

            Section("Other Trigger Options") {
                BulletRow(
                    icon: "mic.fill",
                    title: "Siri",
                    detail: "Say \"Toggle Recording with JustSpeakToIt\" or \"Start Recording with JustSpeakToIt\"."
                )
                BulletRow(
                    icon: "square.grid.2x2.fill",
                    title: "Control Center",
                    detail: "On iOS 18 and later add the Shortcut control via Customise Controls → Add a Control."
                )
                BulletRow(
                    icon: "lock.iphone",
                    title: "Lock Screen / Home Screen widget",
                    detail: "Add a Shortcuts widget and pick your Toggle Recording shortcut."
                )
                BulletRow(
                    icon: "hand.tap.fill",
                    title: "Back Tap",
                    detail: "Settings → Accessibility → Touch → Back Tap. "
                        + "Assign your shortcut to a double or triple tap."
                )
            }

            Section("What Runs") {
                Label("Live model: \(settings.selectedModel)", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Recording uses the live model from the Transcription section above. "
                        + "If the chosen model needs an API key that isn't set, JustSpeakToIt "
                        + "falls back to Apple Speech (on-device) so the trigger still works."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Action Button & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
        }
    }
}

private struct BulletRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Post-Processing Settings View

struct PostProcessingSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Model") {
                ForEach(Array(AppSettings.postProcessingModels.enumerated()), id: \.offset) { _, model in
                    Button {
                        settings.postProcessingModel = model.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .foregroundStyle(.primary)
                                Text(model.description ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            IOSModelCredentialStatusView(
                                availability: ModelCredentialResolver.availability(
                                    for: model.id,
                                    purpose: .postProcessing,
                                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                )
                            )

                            if settings.postProcessingModel == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            Section("Effective Policy Preview") {
                Text(TranscriptCleanupPolicy.systemPrompt())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Post-Processing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - API Keys View

// swiftlint:disable:next type_body_length
struct APIKeysView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deepgramKey = ""
    @State private var openRouterKey = ""
    @State private var openAIKey = ""
    @State private var elevenLabsKey = ""
    @State private var cartesiaKey = ""
    @State private var sonioxKey = ""
    @State private var modulateKey = ""
    @State private var assemblyAIKey = ""
    @State private var gladiaKey = ""
    @State private var xAIKey = ""
    @State private var isValidating = false
    @State private var validationMessage: String?
    @State private var showingValidation = false
    @State private var searchText = ""
    @State private var statusFilter: APIKeyStatusFilter = .all
    @State private var sortOrder: APIKeySortOrder = .name

    private struct KeyPresentation {
        let title: String
        let systemImage: String
        let help: String
    }

    private var allEntries: [APIKeyListEntry] {
        Self.entries(for: settings)
    }

    fileprivate static func entries(for settings: AppSettings) -> [APIKeyListEntry] {
        [
            APIKeyListEntry(
                id: "deepgram", title: "Deepgram", category: "Transcription", isStored: settings.hasDeepgramKey
            ),
            APIKeyListEntry(
                id: "elevenlabs", title: "ElevenLabs", category: "Transcription & Voice Output",
                isStored: settings.hasElevenLabsKey
            ),
            APIKeyListEntry(
                id: "openrouter", title: "OpenRouter", category: "Post-processing", isStored: settings.hasOpenRouterKey
            ),
            APIKeyListEntry(
                id: "openai", title: "OpenAI", category: "Transcription", isStored: settings.hasOpenAIKey
            ),
            APIKeyListEntry(
                id: "cartesia", title: "Cartesia", category: "Transcription", isStored: settings.hasCartesiaKey
            ),
            APIKeyListEntry(
                id: "soniox", title: "Soniox", category: "Transcription & Voice Output",
                isStored: settings.hasSonioxKey
            ),
            APIKeyListEntry(
                id: "modulate", title: "Modulate", category: "Transcription", isStored: settings.hasModulateKey
            ),
            APIKeyListEntry(
                id: "assemblyai", title: "AssemblyAI", category: "Transcription",
                isStored: settings.hasAssemblyAIKey
            ),
            APIKeyListEntry(
                id: "gladia", title: "Gladia", category: "Transcription", isStored: settings.hasGladiaKey
            ),
            APIKeyListEntry(
                id: "xai", title: "xAI", category: "Transcription", isStored: settings.hasXAIKey
            )
        ]
    }

    private var visibleEntries: [APIKeyListEntry] {
        APIKeyListQuery.apply(
            to: allEntries,
            searchText: searchText,
            status: statusFilter,
            sortOrder: sortOrder
        )
    }

    var body: some View {
        Form {
            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No API Keys",
                    systemImage: "key.slash",
                    description: Text("Try another search or status filter.")
                )
            } else {
                ForEach(visibleEntries) { entry in
                    apiKeySection(for: entry)
                }
            }
        }
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .listSectionSpacing(settings.visualDensity.listSectionSpacing)
        .navigationTitle("API Keys")
        .navigationBarTitleDisplayMode(
            settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
                ? .inline
                : .automatic
        )
        .controlSize(settings.visualDensity.isCompact ? .small : .regular)
        .searchable(text: $searchText, prompt: "Provider or use")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Status", selection: $statusFilter) {
                        ForEach(APIKeyStatusFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(APIKeySortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Label("Filter and Sort", systemImage: statusFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isValidating {
                    ProgressView()
                } else {
                    Button("Save") {
                        saveKeys()
                    }
                    .disabled(
                        deepgramKey.isEmpty
                            && openRouterKey.isEmpty
                            && openAIKey.isEmpty
                            && elevenLabsKey.isEmpty
                            && cartesiaKey.isEmpty
                            && sonioxKey.isEmpty
                            && modulateKey.isEmpty
                            && assemblyAIKey.isEmpty
                            && gladiaKey.isEmpty
                            && xAIKey.isEmpty
                    )
                }
            }
        }
        .alert("Validation", isPresented: $showingValidation) {
            Button("OK") {}
        } message: {
            Text(validationMessage ?? "Keys saved")
        }
    }

    private func apiKeySection(for entry: APIKeyListEntry) -> some View {
        let presentation = presentation(for: entry.id)
        return Section {
            SecureField("API Key", text: draftBinding(for: entry.id))
                .textContentType(.password)
                .autocorrectionDisabled()

            if entry.isStored && draftBinding(for: entry.id).wrappedValue.isEmpty {
                Button("Clear Stored Key", role: .destructive) {
                    clearStoredKey(for: entry.id)
                }
            }
        } header: {
            HStack {
                Label(presentation.title, systemImage: presentation.systemImage)
                Spacer()
                Text(entry.isStored ? "Stored" : "Missing")
                    .font(.caption)
                    .foregroundStyle(entry.isStored ? .green : .secondary)
            }
        } footer: {
            Text(presentation.help)
                .font(.caption)
        }
    }

    private func presentation(for id: String) -> KeyPresentation {
        switch id {
        case "deepgram":
            return KeyPresentation(
                title: "Deepgram",
                systemImage: "waveform",
                help: "Get your key from deepgram.com."
            )
        case "elevenlabs":
            return KeyPresentation(
                title: "ElevenLabs", systemImage: "mic.and.signal.meter", help: "Get your key from elevenlabs.io."
            )
        case "openrouter":
            return KeyPresentation(
                title: "OpenRouter",
                systemImage: "network",
                help: "Get your key from openrouter.ai."
            )
        case "openai":
            return KeyPresentation(
                title: "OpenAI", systemImage: "brain.head.profile", help: "Get your key from platform.openai.com."
            )
        case "cartesia":
            return KeyPresentation(
                title: "Cartesia", systemImage: "waveform.circle", help: "Get your key from cartesia.ai."
            )
        case "soniox":
            return KeyPresentation(
                title: "Soniox", systemImage: "waveform.badge.mic", help: "Get your key from soniox.com."
            )
        case "modulate":
            return KeyPresentation(
                title: "Modulate", systemImage: "waveform.badge.magnifyingglass", help: "Get your key from modulate.ai."
            )
        case "assemblyai":
            return KeyPresentation(
                title: "AssemblyAI", systemImage: "waveform.badge.plus", help: "Get your key from assemblyai.com."
            )
        case "xai":
            return KeyPresentation(
                title: "xAI", systemImage: "waveform.badge.mic", help: "Get your key from console.x.ai."
            )
        default:
            return KeyPresentation(
                title: "Gladia", systemImage: "waveform.badge.exclamationmark", help: "Get your key from gladia.io."
            )
        }
    }

    private func draftBinding(for id: String) -> Binding<String> {
        switch id {
        case "deepgram": return $deepgramKey
        case "elevenlabs": return $elevenLabsKey
        case "openrouter": return $openRouterKey
        case "openai": return $openAIKey
        case "cartesia": return $cartesiaKey
        case "soniox": return $sonioxKey
        case "modulate": return $modulateKey
        case "assemblyai": return $assemblyAIKey
        case "xai": return $xAIKey
        default: return $gladiaKey
        }
    }

    private func clearStoredKey(for id: String) {
        switch id {
        case "deepgram": settings.deepgramAPIKey = ""
        case "elevenlabs": settings.elevenLabsAPIKey = ""
        case "openrouter": settings.openRouterAPIKey = ""
        case "openai": settings.openAIAPIKey = ""
        case "cartesia": settings.cartesiaAPIKey = ""
        case "soniox": settings.sonioxAPIKey = ""
        case "modulate": settings.modulateAPIKey = ""
        case "assemblyai": settings.assemblyAIAPIKey = ""
        case "xai": settings.xAIAPIKey = ""
        default: settings.gladiaAPIKey = ""
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func saveKeys() {
        Task {
            isValidating = true
            var messages: [String] = []

            // Validate and save Deepgram key
            if !deepgramKey.isEmpty {
                let validator = DeepgramAPIKeyValidator()
                let result = await validator.validate(deepgramKey)

                switch result.outcome {
                case .success:
                    settings.deepgramAPIKey = deepgramKey
                    deepgramKey = ""
                    messages.append("✓ Deepgram key validated and saved")
                    // Auto-select Deepgram as the provider now that we have a key
                    settings.reconfigureDefaultProvider()
                case .failure(let message):
                    messages.append("✗ Deepgram: \(message)")
                }
            }

            // Validate and save ElevenLabs key
            if !elevenLabsKey.isEmpty {
                let validator = ElevenLabsSTTAPIKeyValidator()
                let result = await validator.validate(elevenLabsKey)

                switch result.outcome {
                case .success:
                    settings.elevenLabsAPIKey = elevenLabsKey
                    elevenLabsKey = ""
                    messages.append("✓ ElevenLabs API key validated and saved")
                case .failure(let message):
                    messages.append("✗ ElevenLabs: \(message)")
                }
            }

            // Save OpenRouter key (no validation endpoint available)
            if !openRouterKey.isEmpty {
                settings.openRouterAPIKey = openRouterKey
                openRouterKey = ""
                messages.append("✓ OpenRouter key saved")
            }

            // Save OpenAI key (no cheap validation endpoint)
            if !openAIKey.isEmpty {
                settings.openAIAPIKey = openAIKey
                openAIKey = ""
                messages.append("✓ OpenAI key saved")
            }

            // Save Cartesia key (no cheap validation endpoint)
            if !cartesiaKey.isEmpty {
                settings.cartesiaAPIKey = cartesiaKey
                cartesiaKey = ""
                messages.append("✓ Cartesia key saved")
            }

            // The same Soniox credential powers transcription and voice output.
            if !sonioxKey.isEmpty {
                settings.sonioxAPIKey = sonioxKey
                sonioxKey = ""
                messages.append("✓ Soniox key saved for transcription and voice output")
            }

            // Save Modulate key (no cheap validation endpoint)
            if !modulateKey.isEmpty {
                settings.modulateAPIKey = modulateKey
                modulateKey = ""
                messages.append("✓ Modulate key saved")
            }

            // Save AssemblyAI key (no cheap validation endpoint)
            if !assemblyAIKey.isEmpty {
                settings.assemblyAIAPIKey = assemblyAIKey
                assemblyAIKey = ""
                messages.append("✓ AssemblyAI key saved")
            }

            // Save Gladia key (no cheap validation endpoint)
            if !gladiaKey.isEmpty {
                settings.gladiaAPIKey = gladiaKey
                gladiaKey = ""
                messages.append("✓ Gladia key saved")
            }

            // Save xAI key (validated when the realtime session connects)
            if !xAIKey.isEmpty {
                settings.xAIAPIKey = xAIKey
                xAIKey = ""
                messages.append("✓ xAI key saved")
            }

            isValidating = false
            validationMessage = messages.joined(separator: "\n")
            showingValidation = true
        }
    }
}

// MARK: - Privacy View

struct PrivacyView: View {
    private var transcriptionProviders: [LiveTranscriptionProviderID] {
        LiveTranscriptionRouting.iOSSupportedProviders
    }

    private func processingDescription(for provider: LiveTranscriptionProviderID) -> String {
        if provider == .apple {
            return "Microphone audio is transcribed on-device when supported; Apple's speech service may otherwise "
                + "process it on its servers."
        }
        return "Microphone audio is streamed to \(provider.displayName) for transcription."
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // swiftlint:disable:next line_length
                    Text("Speak is designed with privacy in mind. Your audio and transcripts are processed according to the provider you select.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Audio Processing") {
                ForEach(transcriptionProviders, id: \.self) { provider in
                    FeatureRow(
                        icon: provider == .apple ? "mic.fill" : "network",
                        title: provider == .apple ? "Apple Speech" : provider.displayName,
                        description: processingDescription(for: provider)
                    )
                }

                Text("When enabled, post-processing sends transcript text to OpenRouter, and voice output sends "
                    + "text to Soniox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API Keys") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Secure Storage", systemImage: "lock.fill")
                        .font(.headline)
                    // swiftlint:disable:next line_length
                    Text("API keys are encrypted in your device Keychain and never leave your device except when syncing via iCloud Keychain (end-to-end encrypted).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Network Activity") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptionProviders, id: \.self) { provider in
                        InfoRow(
                            label: provider == .apple ? "Apple Speech" : provider.displayName,
                            value: provider == .apple ? "On-device when supported" : "During transcription"
                        )
                    }
                    InfoRow(label: "Send to Mac", value: "Local network only")
                    InfoRow(label: "iCloud Sync", value: "Settings & keys (optional)")
                }
                .font(.caption)
            }

            Section("What We Don't Collect") {
                VStack(alignment: .leading, spacing: 8) {
                    CheckRow(text: "No usage analytics")
                    CheckRow(text: "No personal information")
                    CheckRow(text: "No transcription content")
                    CheckRow(text: "No third-party tracking")
                }
            }

            Section("Permissions") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speak requires these permissions:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    PermissionRow(icon: "mic.fill", name: "Microphone", required: true)
                    PermissionRow(icon: "waveform", name: "Speech Recognition", required: true)
                    PermissionRow(icon: "network", name: "Local Network", required: false)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.brandLagoon)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct CheckRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }
}

struct PermissionRow: View {
    let icon: String
    let name: String
    let required: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.brandLagoon)
                .frame(width: 24)
            Text(name)
                .font(.caption)
            Spacer()
            Text(required ? "Required" : "Optional")
                .font(.caption2)
                .foregroundStyle(required ? .red : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(required ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1), in: Capsule())
        }
    }
}

// MARK: - CloudKit Sync Settings

struct CloudKitSyncSettingsSection: View {
    @ObservedObject private var syncEngine = HistorySyncEngine.shared
    @StateObject private var historyManager = iOSHistoryManager.shared
    @State private var isSyncing = false

    var body: some View {
        let availability = SyncAvailability.current(iCloudCloudKitAvailable: syncEngine.state.isCloudAvailable)

        // CloudKit status
        HStack {
            Label("iCloud History Sync", systemImage: "icloud")
            Spacer()
            Text(availability.iCloudCloudKitAvailable ? "Active" : "Unavailable")
                .foregroundStyle(
                    availability.iCloudCloudKitAvailable ? .green : .secondary
                )
        }
        .accessibilityElement(children: .combine)

        if availability.iCloudCloudKitAvailable {
            // Sync counts
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Synced Entries")
                        .font(.subheadline)
                    Text("\(historyManager.syncedCount) of \(historyManager.items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if historyManager.unsyncedCount > 0 {
                    Text("\(historyManager.unsyncedCount) pending")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color.orange.opacity(0.12),
                            in: Capsule()
                        )
                } else if !historyManager.items.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            // Last sync time
            if let lastSync = syncEngine.state.lastSyncTime {
                LabeledContent("Last Sync") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            // Error display
            if let error = syncEngine.state.error {
                Label {
                    Text(error.localizedDescription)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }

            // Manual sync button
            Button {
                isSyncing = true
                Task {
                    await historyManager.triggerSync()
                    isSyncing = false
                }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncing || syncEngine.state.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isSyncing || syncEngine.state.isSyncing)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    availability.transportAvailable
                        ? "Sign in to iCloud to sync history automatically. Until then, Bonjour Transport "
                            + "can send new sessions to a paired Mac on your local network."
                        : "Sign in to iCloud in Settings to sync transcription history across your devices."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CloudKitKeySyncSettingsSection: View {
    @ObservedObject private var keySync = CloudKitKeySync.shared
    @State private var passphrase = ""
    @State private var syncError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Encrypted API-Key Sync", systemImage: "lock.icloud")
                Spacer()
                Text(keySync.status.message)
                    .foregroundStyle(keySync.status.isEnabled ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            if !keySync.status.isEnabled {
                SecureField("Sync passphrase", text: $passphrase)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .privacySensitive()

                Button {
                    Task {
                        do {
                            try await keySync.enable(passphrase: passphrase)
                            await AppSettings.shared.reloadSyncedAPIKeys()
                            passphrase = ""
                            syncError = nil
                        } catch {
                            syncError = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Enable API-Key Sync", systemImage: "lock.open")
                }
                .disabled(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                HStack {
                    Button {
                        Task {
                            do {
                                try await keySync.syncNow()
                                await AppSettings.shared.reloadSyncedAPIKeys()
                                syncError = nil
                            } catch {
                                syncError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Sync Keys Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(keySync.status.isSyncing)

                    Button("Disable", role: .destructive) {
                        Task { await keySync.disable() }
                    }
                }
            }

            if let syncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Keys are encrypted on this device before they are written to your private CloudKit database.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            _ = await AppSettings.shared.syncCloudKitKeys()
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}

#Preview("Privacy") {
    NavigationStack {
        PrivacyView()
    }
}

private extension SettingsView {
    @MainActor
    private var transcriptionLocationBinding: Binding<IOSTranscriptionLocation> {
        Binding(
            get: { settings.transcriptionLocation },
            set: { settings.selectTranscriptionLocation($0) }
        )
    }

    @MainActor
    private var remoteTranscriptionModeBinding: Binding<IOSTranscriptionMode> {
        Binding(
            get: { settings.remoteTranscriptionMode },
            set: { settings.selectRemoteTranscriptionMode($0) }
        )
    }

    @MainActor
    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { settings.selectedModel },
            set: { newValue in
                settings.selectedModel = newValue
                presentMissingTranscriptionAPIKeyAlertIfNeeded(for: newValue)
            }
        )
    }

    @MainActor
    private func presentMissingTranscriptionAPIKeyAlertIfNeeded(for model: String) {
        guard let alert = IOSMissingTranscriptionAPIKeyAlert(modelID: model, settings: settings) else {
            return
        }
        missingTranscriptionAPIKeyAlert = alert
    }
}

private extension View {
    func iosMissingTranscriptionAPIKeyAlert(
        alert: Binding<IOSMissingTranscriptionAPIKeyAlert?>,
        showingAPIKeys: Binding<Bool>,
        openURL: OpenURLAction
    ) -> some View {
        self.alert(
            alert.wrappedValue?.title ?? "API key required",
            isPresented: Binding(
                get: { alert.wrappedValue != nil },
                set: { if !$0 { alert.wrappedValue = nil } }
            ),
            presenting: alert.wrappedValue
        ) { presentedAlert in
            Button("Add API Key") {
                alert.wrappedValue = nil
                showingAPIKeys.wrappedValue = true
            }
            if let url = presentedAlert.apiKeyURL {
                Button("Get API Key") {
                    alert.wrappedValue = nil
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {
                alert.wrappedValue = nil
            }
        } message: { presentedAlert in
            Text(presentedAlert.message)
        }
    }
}

private struct IOSMissingTranscriptionAPIKeyAlert: Identifiable {
    let id = UUID()
    let providerName: String
    let modelName: String
    let apiKeyURL: URL?

    var title: String { "API key required" }

    var message: String {
        "\(providerName) needs an API key for transcription with \(modelName). Add it now and try again."
    }

    @MainActor
    init?(modelID: String, settings: AppSettings) {
        // Provider metadata is single-sourced from SpeakCore's live routing so
        // every provider with a missing key triggers the alert, matching Mac.
        guard let route = LiveTranscriptionRouting.route(for: modelID),
              let apiKeyIdentifier = route.apiKeyIdentifier,
              !settings.storedAPIKeyIdentifiers.contains(apiKeyIdentifier) else {
            return nil
        }

        providerName = route.provider.displayName
        modelName = ModelCatalog.friendlyName(for: modelID)
        apiKeyURL = route.provider.apiKeyURL
    }
}
#endif
