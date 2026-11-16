import Foundation
import SpeakCore
import SpeakDesktop

// The host actor's stored state. Its value types live beside it
// (DesktopHostControllerSettings, DesktopHostRecordingValues), and related
// fields are grouped into domain state (DesktopHostControllerState): model
// discovery, correction learning, connection warming, migration work and
// credential work (`voiceCredentials`). Every value is read and written only
// on this actor.
package actor DesktopHostController<Platform: DesktopHostPlatform> {
    package nonisolated let directory: URL
    package let effects: any DesktopHostEffects<Platform>
    package nonisolated let store: DesktopRecordingStore
    /// Inactive until the app entry point activates it for a real session.
    package nonisolated let telemetry: DesktopTelemetry
    let uploadStaging: SharedMultipartUploadStaging
    package let modelCatalog: OpenRouterAudioCatalogStore
    var modelDiscovery = DesktopHostModelDiscoveryState()
    let profileStore: DesktopDictationProfileStore
    package var profiles: [DictationProfile] {
        didSet { invalidateConnectionPreWarming(resetCapture: true) }
    }
    var manualProfileID: UUID? {
        didSet { invalidateConnectionPreWarming(resetCapture: true) }
    }
    var profileEditorState: DesktopHostProfileEditorState?
    var profileWarning: String?
    package var settings: Settings {
        didSet {
            invalidateConnectionPreWarming(resetCapture: true)
            cancelCorrectionObservation()
            if !correctionLearningEnabled { revokeCorrectionLearningConsent() }
        }
    }
    var correctionLearning = DesktopHostCorrectionLearningState()
    var vocabularyLoad: Task<DesktopVocabulary, Error>?
    var configurationEditor: DesktopHostConfigurationEditorState?
    var connectionWarm = DesktopHostConnectionWarmState() {
        didSet { if oldValue.task?.id != connectionWarm.task?.id { reconcileSystemResources() } }
    }
    var capturePreparation: (deviceID: String, value: any DesktopCapturePreparation)? {
        didSet { reconcileSystemResources() }
    }
    var capturePreparationWatch: Task<Void, Never>?
    var capturePreparationPollInterval: Duration = .seconds(1)
    var shortcutPressMicrophone: (id: UUID, capture: any DesktopRecordingCapture)? {
        didSet { reconcileSystemResources() }
    }
    package var recording: Recording? { didSet { reconcileSystemResources() } }
    var recordingCapturePolicy: (recordID: UUID, value: DesktopHostCapturePolicy)?
    var ownedCaptureStartup: DesktopHostOwnedStartupHandle? { didSet { reconcileSystemResources() } }
    let ownedDictationCapability: DesktopHostOwnedDictationCapability?
    var ownedDictation: DesktopHostOwnedDictationHandle<Platform>? { didSet { reconcileSystemResources() } }
    var ownedDictationAdmission: DesktopHostOwnedDictationAdmission<Platform>?
    package var recordingTail: (recordID: UUID, task: Task<Void, Never>)?
    var isReady = false
    package var busy = false
    var busyOperations = 0
    package var closed = false {
        didSet {
            if closed {
                configurationEditor = nil
                connectionWarm.approved = false
                invalidateConnectionPreWarming(resetCapture: true)
                revokeCorrectionLearningConsent()
                capturedCleanup.removeAll()
                retireCleanupPresentation()
                endSavedAudioPlaybackIfStopped()
                reconcileSystemResources()
            }
        }
    }
    /// Set once `close()` stops waiting; later calls return it.
    var shutdownReport: DesktopHostShutdownReport?
    /// How long `close()` waits in all for cancelled work to end.
    package nonisolated let shutdownGrace: Duration
    package var activeOperations = 0 {
        didSet {
            if activeOperations > 0 {
                pauseConnectionPreWarming()
            } else {
                reconcileConnectionPreWarming()
                reconcileCapturePreparation()
            }
        }
    }
    var operationWaiters: [CheckedContinuation<Void, Never>] = []
    /// API key identifiers whose last provider check failed, for the API Keys Errors filter.
    var apiKeyCheckFailures: Set<String> = []
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    package var transcript = ""
    package var hotKeySession = DesktopHostHotKeySessionState()
    package var readAloudState = Platform.makeReadAloudState() { didSet { reconcileSystemResources() } }
    /// Actual History ownership of active voice work; nil for every non-History source.
    package var voiceOutputRecordID: UUID?
    package var voiceTextImportTask: Task<Void, Never>?
    package var voiceTextImportRequestID: String?
    package var voiceGenerationTask: Task<Void, Never>?
    package var voiceSettingsRevision: UInt64 = 0
    /// Voice key reads and writes, provider key writes and the provider key edit queue.
    package var voiceCredentials = DesktopHostVoiceCredentialState()
    package var voiceAccountWorkers = 0
    package var voiceSynthesisWorkers = 0
    package var voiceAccountOutputTicket: DesktopPlaybackRequests.Ticket?
    package var generatedVoice: DesktopGeneratedVoiceResult?
    package var voiceUsage = DesktopVoiceUsageState()
    package var voiceDiscovery = DesktopVoiceDiscoveryState()
    /// The one History Play or Read aloud request that may still start audio or report.
    package var playbackRequests = DesktopPlaybackRequests()
    package var history: [UUID: DesktopRecordingStore.Record] = [:]
    /// The newest History records for the command palette, which searches on
    /// the native UI thread without waiting for this actor.
    package nonisolated let paletteHistory = CommandPaletteHistorySnapshot()
    var issueReportSession: DesktopHostIssueReportSession?
    /// Folded search text per record, refreshed only when a record is saved so
    /// each keystroke filters cached strings instead of re-normalising transcripts.
    package var historySearchText: [UUID: String] = [:]
    var historyQuery = ""
    var historyFilter = HistorySearchQuery.none
    var historyFilterDraft = DesktopHistoryFilter.none
    /// How many matching History rows the native list builds; see `HistoryPageWindow`.
    var historyPage = HistoryPageWindow()
    package var selectedHistoryID: UUID? {
        didSet { retireCleanupPresentation() }
    }
    package var transcriptVariant: DesktopTranscriptVariant = .processed {
        didSet { retireCleanupPresentation() }
    }
    var transcriptionTask: Task<TranscriptionResult, Error>?
    var automationTranscriptions: [UUID: Task<TranscriptionResult, Error>] = [:]
    var automationPreferenceChanged: (@Sendable () async -> Void)?
    var voiceCommandTask: Task<String?, Error>?
    var voiceEdit = DesktopHostVoiceEditState()
    var postProcessingTask: Task<DesktopPostProcessing.Outcome, Error>?
    var postProcessingID: UUID? {
        didSet { if postProcessingID != oldValue { retireCleanupPresentation() } }
    }
    var cleanupNativeTicket: UInt64?
    var cleanupPresentationEpoch = UUID()
    var capturedCleanup: [UUID: DesktopHostCleanupInput] = [:]
    package let localCleanup: DesktopLocalLLMStore?
    var localCleanupTask: Task<Void, Never>?
    var localCleanupNotice = ""
    var localCleanupPercent = -1
    var localCleanupOperationID: UUID?
    var localCleanupPresenting = false {
        didSet { retireCleanupPresentation() }
    }
    var localCleanupPresenter: UnsafeMutableRawPointer?
    var localCleanupChoices: [String] = []
    package var microphoneWarning: String?
    /// A blocked essential permission, appended to the ready status.
    var permissionWarning: String?
    var cancellationRequested = false {
        didSet { if cancellationRequested { retireCleanupPresentation() } }
    }
    /// The recording the user cancelled while `keepAudioOnCancel` was off.
    var discardCancelledRecordingID: UUID?
    var historyDeletionInProgress = false
    var historyDeletionTask: Task<Void, Never>?
    var folderRevealTask: Task<Void, Error>?
    var recordingLocation = DesktopHostRecordingLocationState()
    var audioCleanupTask: Task<Void, Never>?
    var audioCleanupConfirmation: (id: UUID, snapshot: DesktopRecordingAudioSnapshot)?
    var migrationWork = DesktopHostMigrationWork()
    var liveUpdates: Task<Void, Never>?
    var liveFinalisation: DesktopLiveSession?
    /// The recording the HUD follows, from Record until its result.
    var hudRecording: UUID?
    var hudExpanded = false
    package var outputSlot = DesktopHostOutputState<Platform>()
    // Installed once iCloud sync is configured.
    package var cloudSync = DesktopHostSyncHooks()
    /// Downloads, progress and the on-device runtime for Local models.
    package var localModels = Platform.makeLocalModelsState()
    /// At most one audible native History playback; its status presenter is
    /// installed by preparePlayback once this actor exists.
    package let playback = Platform.makePlayback()
    var recordingFeedback: DesktopRecordingFeedback?
    var recordingFeedbackPreview: Task<Void, Never>?
    package var comparisons: DesktopComparisonStore?
    var comparisonSync: DesktopHostComparisonSyncHooks?
    var comparisonVisible = false {
        didSet { retireCleanupPresentation() }
    }
    var comparisonInitialization: DesktopComparisonStoreLoading?
    var comparisonAdmissionTask: Task<Void, Never>?
    var comparisonBatch: DesktopComparisonBatch?
    let comparisonOperations = DesktopComparisonOperations()
    let comparisonStaging = DesktopComparisonStaging()
    package var comparisonTask: Task<Void, Never>?
    package var comparisonFinalization: Task<Void, Never>?
    var comparisonUpdates: Task<Void, Never>?
    package var comparisonCapture: DesktopHostComparisonCapture? { didSet { reconcileSystemResources() } }
    package var comparisonLive: DesktopComparisonLive?
    package var comparisonSelection: UUID?
    var comparisonReference: UUID?
    var comparisonPresentationRevision: UInt64 = 0
    let comparisonWords = DesktopComparisonWordPresentation()
    package var comparisonGeneration = UUID()
    var comparisonOwnedRoundIDs: Set<UUID> = []
    package var comparisonLanguage: String?
    package var comparisonPending: ModelComparisonRound?
    package var comparisonNotice = "Select models and an input to begin."
    var handsFreeMachine = HandsFreeDictationMachine()
    var handsFreeRun: DesktopHandsFreeRun<Platform>? { didSet { reconcileSystemResources() } }
    /// Holds listed in "System resources in use", by claim key; see DesktopHostSystemResources.
    var systemResourceHolds: [String: SystemResourceToken] = [:]
    /// Replaced only by tests.
    var systemResourceRegistry = SystemResourceRegistry.shared
    /// The History recording whose saved audio the player holds, watched until it stops.
    var savedAudioPlayback: (recordID: UUID, watch: Task<Void, Never>)? { didSet { reconcileSystemResources() } }

    package init(
        directory: URL, effects: any DesktopHostEffects<Platform>, shutdownGrace: Duration = DesktopHostShutdown.grace,
        ownedDictationCapability: DesktopHostOwnedDictationCapability? = nil
    ) throws {
        self.directory = directory
        self.effects = effects
        self.ownedDictationCapability = ownedDictationCapability
        self.shutdownGrace = shutdownGrace
        self.store = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
        self.telemetry = DesktopTelemetry(directory: directory)
        self.uploadStaging = Platform.uploadStaging(directory: directory.appendingPathComponent("Uploads"))
        let profileStore = DesktopDictationProfileStore(directory: directory)
        self.profileStore = profileStore
        let loadedProfiles = try Self.loadProfiles(from: profileStore)
        self.profiles = loadedProfiles.profiles
        self.profileWarning = loadedProfiles.warning
        let settingsURL = directory.appendingPathComponent("settings.json")
        var loadedSettings: Settings
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            loadedSettings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
        } else {
            loadedSettings = Settings()
        }
        let favoriteKey = VoiceFavoritePreference.key
        if Platform.voiceConfigurationKeys.contains(favoriteKey),
           let configuration = loadedSettings.configuration, configuration.values[favoriteKey] != nil {
            let exported = try Platform.exportVoiceConfiguration(loadedSettings.voiceOutput, over: configuration)
            var voice = loadedSettings.voiceOutput
            _ = try Platform.importVoiceConfiguration(
                from: DesktopConfiguration(values: exported.values.filter { $0.key == favoriteKey }), into: &voice)
            loadedSettings.voiceOutput = voice
            loadedSettings.configuration = try DesktopConfiguration(
                values: configuration.values.filter { $0.key != favoriteKey })
        }
        try Self.importStoredVoiceSelection(into: &loadedSettings)
        self.localModels = try Platform.loadLocalModels(directory: directory)
        self.localCleanup = try Platform.makeLocalCleanup(directory: directory)
        modelCatalog = try loadedSettings.preservingArchiveModelPresence {
            try Self.prepareModelCatalog(directory: directory, settings: &$0)
        }
        if let processing = loadedSettings.postProcessing {
            loadedSettings.postProcessing = DesktopPostProcessing.migrated(processing)
        }
        if let configuration = loadedSettings.configuration {
            loadedSettings.configuration = try DesktopPostProcessingConfiguration.importOptions(
                from: configuration, into: &loadedSettings.postProcessing
            )
            loadedSettings.configuration = try Platform.importingAppSwitchPolicy(
                from: loadedSettings.configuration ?? configuration, into: &loadedSettings.textOutput
            )
        }
        self.settings = loadedSettings
    }

    /// Self-test only: startup without model discovery, which could reach the
    /// network with a real saved credential.
    package func markReadyForSelfTest() { isReady = true }
}
