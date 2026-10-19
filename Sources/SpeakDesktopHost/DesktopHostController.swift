import Foundation
import SpeakCore
import SpeakDesktop

// Host actor state (settings, recording, correction learning, vocabulary) stays one cohesive inventory.
// swiftlint:disable:next type_body_length
package actor DesktopHostController<Platform: DesktopHostPlatform> {
    package struct SettingsValues: Codable, Sendable {
        package var model = ModelCatalog.defaultBatchTranscriptionModel
        package var postProcessing: DesktopPostProcessing.Options?
        package var microphoneDeviceID: String?
        package var batchModel: String?
        package var liveModel: String?
        // Absent keys keep the native smart insert-at-cursor default.
        package var textOutput: Platform.TextOutputOptions?
        package var hotKey: Platform.HotKeySettings?
        package var voiceOutput: Platform.VoiceOutputSettings?
        package var automationEnabled: Bool?
        /// Device-local approval, never included in portable configuration.
        package var automationLocalConsent: Bool?
        package var localModel: String?
        /// Last on-device live model (`local/streaming/whisperkit/...`).
        package var localLiveModel: String?
        package var localUseGPU: Bool?
        /// Device-local Azure resource, under the Apple apps' key.
        package var azureSpeechResourceEndpoint: String?
        package var appearance: DesktopAppearance?
        /// Last reached registration for hosts that cannot read it back.
        package var runAtLogin: Bool?
        package var configuration: DesktopConfiguration?
        /// Device-local approval; portable imports cannot grant service access.
        package var livePolishApproved: Bool?
    }

    @dynamicMemberLookup
    package struct Settings: Codable, Sendable {
        private var values = SettingsValues()
        private var preserved: [String: AnyCodable] = [:]
        package init() {}

        package subscript<Value>(dynamicMember keyPath: WritableKeyPath<SettingsValues, Value>) -> Value {
            get { values[keyPath: keyPath] }
            set { values[keyPath: keyPath] = newValue }
        }

        package init(from decoder: Decoder) throws {
            values = try SettingsValues(from: decoder)
            let container = try decoder.singleValueContainer()
            let all = try container.decode([String: AnyCodable].self)
            try adoptStoredStreamingPreference(all)
            var configuration = values.configuration?.values ?? [:]
            let warmKey = DesktopConnectionPreWarming.preferenceKey
            if configuration[warmKey] == nil { configuration[warmKey] = all[warmKey] }
            configuration.removeValue(forKey: DesktopConnectionPreWarming.approvalProjectionKey)
            if values.configuration != nil || configuration[warmKey] != nil {
                values.configuration = try DesktopConfiguration(values: configuration)
            }
            let known: Set<String> = [
                "model", "postProcessing", "microphoneDeviceID", "batchModel", "liveModel", "textOutput",
                "hotKey", "voiceOutput", "automationEnabled", "automationLocalConsent", "localModel", "localUseGPU",
                "azureSpeechResourceEndpoint", "appearance", "runAtLogin", "configuration", "livePolishApproved",
                "localLiveModel",
                DesktopConnectionPreWarming.preferenceKey, DesktopConnectionPreWarming.approvalProjectionKey
            ]
            preserved = all.filter { !known.contains($0.key) }
            try adoptStoredPreferences(DesktopConfiguration.pronunciationPreferenceKeys)
            try adoptStoredPreferences(DesktopConfiguration.modulatePreferenceKeys)
            let voiceKeys = VoiceSelectionPreference.keys.intersection(Platform.voiceConfigurationKeys)
            if !voiceKeys.isDisjoint(with: preserved.keys)
                || !voiceKeys.isDisjoint(with: (values.configuration?.values ?? [:]).keys) {
                var configuration = values.configuration?.values ?? [:]
                let claimed = voiceKeys.union(
                    [VoiceSynthesisPreference.quality.key.rawValue].filter {
                        Platform.voiceConfigurationKeys.contains($0)
                    })
                for key in claimed {
                    if configuration[key] == nil { configuration[key] = preserved[key] }
                    preserved.removeValue(forKey: key)
                }
                values.configuration = try DesktopConfiguration(values: configuration)
            }
            guard Platform.self is any DesktopHostAutomationPlatform.Type else { return }
            let key = ApplicationPreferenceKey.enableAutomationServer.rawValue
            preserved.removeValue(forKey: key)
            if let canonical = values.configuration?.values[key] {
                guard case .bool = canonical.storage else {
                    throw DesktopConfigurationError.invalidField("Automation")
                }
            }
            let desired = all[key] ?? values.automationEnabled.map { AnyCodable(.bool($0)) }
            if values.configuration?.values[key] == nil, let desired {
                guard case .bool = desired.storage else {
                    throw DesktopConfigurationError.invalidField("Automation")
                }
                var configuration = values.configuration?.values ?? [:]
                configuration[key] = desired
                values.configuration = try DesktopConfiguration(values: configuration)
            }
        }

        private mutating func adoptStoredPreferences(_ keys: Set<String>) throws {
            guard !keys.isDisjoint(with: preserved.keys) else { return }
            var configuration = values.configuration?.values ?? [:]
            for key in keys {
                if configuration[key] == nil { configuration[key] = preserved[key] }
                preserved.removeValue(forKey: key)
            }
            values.configuration = try DesktopConfiguration(values: configuration)
        }

        private mutating func adoptStoredStreamingPreference(_ all: [String: AnyCodable]) throws {
            let key = DesktopPostProcessingConfiguration.streamingKey
            guard let configuration = values.configuration, let legacy = configuration.values[key] else { return }
            let explicit: Bool
            if case .object(let stored)? = all["postProcessing"]?.storage {
                explicit = stored["streamingEnabled"] != nil
            } else { explicit = false }
            if !explicit {
                _ = try DesktopPostProcessingConfiguration.importOptions(
                    from: DesktopConfiguration(values: [key: legacy]), into: &values.postProcessing
                )
            }
            values.configuration = try DesktopConfiguration(values: configuration.values.filter { $0.key != key })
        }

        package func encode(to encoder: Encoder) throws {
            let known = try JSONDecoder().decode(
                [String: AnyCodable].self, from: JSONEncoder().encode(values)
            )
            var container = encoder.singleValueContainer()
            try container.encode(preserved.merging(known) { _, current in current })
        }
    }

    /// Target, profile and text output are fixed when recording starts; a
    /// later settings change applies only to later recordings.
    package struct Recording {
        package let capture: any DesktopRecordingCapture
        package let context: DesktopCaptureContext
        package let file: PCMRecordingFile
        package let handsFree: Bool
        package var record: DesktopRecordingStore.Record
        package let target: Platform.InsertionTarget?
        package let live: DesktopLiveSession?
        package let profile: DesktopProfileSession
        package let textOutput: Platform.TextOutputOptions
        /// What started this session; a shortcut gesture stops only its own kind.
        package let trigger: HotKeySessionTrigger
    }

    package struct StoppedRecording: Sendable {
        package let record: DesktopRecordingStore.Record
        package let duration: TimeInterval
        package let target: Platform.InsertionTarget?
        package let live: DesktopLiveSession?
        package let profile: DesktopProfileSession
        package let textOutput: Platform.TextOutputOptions
        package var input: DesktopHostRecordingInput?
        package var output: DesktopHostRecordingOutput<Platform> { .init(options: textOutput, target: target) }
    }

    package nonisolated let directory: URL
    package let effects: any DesktopHostEffects<Platform>
    package nonisolated let store: DesktopRecordingStore
    let uploadStaging: SharedMultipartUploadStaging
    package let modelCatalog: OpenRouterAudioCatalogStore
    var modelDiscoveryTask: Task<Void, Never>?
    var modelCatalogRevision: UInt64 = 0
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
    var correctionObservation: DesktopCorrectionObservation?
    var correctionObservationTask: Task<Void, Never>?
    var correctionObservationWait: @Sendable (Double) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
    var correctionLearningRevision: UInt64 = 0
    var correctionLearningApproved = false
    var observationalCorrectionConsent = false
    var correctionLearningNotice: String?
    var vocabularyLoad: Task<DesktopVocabulary, Error>?
    var connectionWarmApproved = false
    var connectionWarmGeneration = UUID()
    var connectionWarmTracker = LiveStreamWarmTracker()
    var connectionWarmCapture: DesktopHostConnectionWarmCapture?
    var connectionWarmTask: (id: UUID, task: Task<Void, Never>)?
    var connectionWarmPending = false
    var connectionWarmCredentialWork = 0
    package var recording: Recording?
    var recordingCapturePolicy: (recordID: UUID, value: DesktopHostCapturePolicy)?
    var ownedCaptureStartup: DesktopHostOwnedStartupHandle?
    let ownedDictationCapability: DesktopHostOwnedDictationCapability?
    var ownedDictation: DesktopHostOwnedDictationHandle<Platform>?
    var ownedDictationAdmission: DesktopHostOwnedDictationAdmission<Platform>?
    package var recordingTail: (recordID: UUID, task: Task<Void, Never>)?
    var isReady = false
    package var busy = false
    var busyOperations = 0
    package var closed = false {
        didSet {
            if closed {
                connectionWarmApproved = false
                invalidateConnectionPreWarming(resetCapture: true)
                revokeCorrectionLearningConsent()
                capturedCleanup.removeAll()
                retireCleanupPresentation()
            }
        }
    }
    /// Set once `close()` stops waiting; later calls return it.
    var shutdownReport: DesktopHostShutdownReport?
    /// How long `close()` waits in all for cancelled work to end.
    package nonisolated let shutdownGrace: Duration
    package var activeOperations = 0 {
        didSet {
            if activeOperations > 0 { pauseConnectionPreWarming() }
            else { reconcileConnectionPreWarming() }
        }
    }
    var operationWaiters: [CheckedContinuation<Void, Never>] = []
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    package var transcript = ""
    package var hotKeySession = DesktopHostHotKeySessionState()
    package var readAloudState = Platform.makeReadAloudState()
    /// Actual History ownership of active voice work; nil for every non-History source.
    package var voiceOutputRecordID: UUID?
    package var voiceTextImportTask: Task<Void, Never>?
    package var voiceTextImportRequestID: String?
    package var voiceGenerationTask: Task<Void, Never>?
    package var voiceSettingsRevision: UInt64 = 0
    package var voiceCredentialEpoch = UUID()
    package var voiceCredentialTask: Task<Void, Never>?
    package var voiceCredentialRequestID: UUID?
    package var voiceCredentialWriteDestination: VoiceOutputCredentialDestination?
    package var voiceCredentialReadTask: Task<Void, Never>?
    package var voiceCredentialReadID: UUID?
    package var voiceCredentialReadDestination: VoiceOutputCredentialDestination?
    package var voiceCredentialReadWorkerDestination: VoiceOutputCredentialDestination?
    package var voiceProviderIssuedSlot: VoiceOutputCredentialSlot?
    package var voiceAccountWorkers = 0
    package var voiceSynthesisWorkers = 0
    package var voiceAccountOutputTicket: DesktopPlaybackRequests.Ticket?
    package var generatedVoice: DesktopGeneratedVoiceResult?
    package var voiceUsage = DesktopVoiceUsageState()
    package var voiceDiscovery = DesktopVoiceDiscoveryState()
    /// The one History Play or Read aloud request that may still start audio or report.
    package var playbackRequests = DesktopPlaybackRequests()
    package var history: [UUID: DesktopRecordingStore.Record] = [:]
    /// Folded search text per record, refreshed only when a record is saved so
    /// each keystroke filters cached strings instead of re-normalising transcripts.
    package var historySearchText: [UUID: String] = [:]
    var historyQuery = ""
    var historyFilter = HistorySearchQuery.none
    var historyFilterDraft = DesktopHistoryFilter.none
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
    var cancellationRequested = false {
        didSet { if cancellationRequested { retireCleanupPresentation() } }
    }
    var historyDeletionInProgress = false
    var historyDeletionTask: Task<Void, Never>?
    var folderRevealTask: Task<Void, Error>?
    var audioCleanupTask: Task<Void, Never>?
    var migrationExportTask: Task<Void, Never>?
    var migrationExportWorker: Task<DesktopMigrationBackup.Outcome, Never>?
    var migrationInspectionTask: Task<Void, Never>?
    var migrationInspectionWorker: Task<DesktopMigrationInspection.Outcome, Never>?
    var audioCleanupConfirmation: (id: UUID, snapshot: DesktopRecordingAudioSnapshot)?
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
    package var comparisonTask: Task<Void, Never>?
    package var comparisonFinalization: Task<Void, Never>?
    var comparisonUpdates: Task<Void, Never>?
    package var comparisonCapture: DesktopHostComparisonCapture?
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
    var handsFreeRun: DesktopHandsFreeRun<Platform>?

    package init(
        directory: URL, effects: any DesktopHostEffects<Platform>, shutdownGrace: Duration = DesktopHostShutdown.grace,
        ownedDictationCapability: DesktopHostOwnedDictationCapability? = nil
    ) throws {
        self.directory = directory
        self.effects = effects
        self.ownedDictationCapability = ownedDictationCapability
        self.shutdownGrace = shutdownGrace
        self.store = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
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
        modelCatalog = try Self.prepareModelCatalog(directory: directory, settings: &loadedSettings)
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

extension DesktopHostController {
    func captureFailed(_ message: String, recordingID: UUID) async {
        if !closed, ownedDictation?.id == recordingID {
            await stopOwnedDictation(requestID: recordingID, reason: message)
            return
        }
        guard !closed, recording?.record.id == recordingID else { return }
        invalidateConnectionPreWarming(resetCapture: true)
        if recording?.handsFree == true, let runID = handsFreeRun?.id {
            await failHandsFree(message, runID: runID)
            return
        }
        await recordingFeedback?.cancelRecording(recordingID)
        beginBusyOperation()
        defer {
            capturedCleanup.removeValue(forKey: recordingID)
            finishBusyOperation()
        }
        var record = recording?.record
        let live = recording?.live
        var stopped: StoppedRecording?
        var failure = message
        do { stopped = try stopCapture() } catch {
            failure += " Capture cleanup failed: \(error.localizedDescription)"
        }
        if let live, var partial = record {
            let snapshot = live.cancel()
            partial.result = liveResult(snapshot.text, record: partial, duration: stopped?.duration ?? 0)
            record = partial
        }
        record?.failure = failure
        do { if let record { try await saveRecord(record) } } catch {
            update("\(message) History error: \(error.localizedDescription)", state: 0)
            return
        }
        if let record { present(record, output: nil) } else {
            reportFailure("Recording stopped and retained: \(message)", for: recordingID, headline: "Recording stopped")
        }
    }

    package func importAudio(path: String, modelIndex: Int) async {
        guard isReady, !busy, !closed, recording == nil,
              DesktopHostModels.all.indices.contains(modelIndex),
              !DesktopHostModels.isLive(DesktopHostModels.all[modelIndex].id),
              !DesktopHostModels.isLocalLive(DesktopHostModels.all[modelIndex].id) else { return }
        cancelOutput()
        guard selectModel(modelIndex) else { return }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        do {
            try await playback.stopAndWait()
            guard !closed else { return }
            _ = try requireCredentialOrLocalModel(settings.model)
            let localModel = beginLocalUse(settings.model) // Held across the save until transcription ends.
            defer { endLocalUse(localModel) }
            let source = URL(fileURLWithPath: path)
            try DesktopHostImport.validate(source)
            let id = UUID()
            let filename = id.uuidString + "." + source.pathExtension
            let destination = directory.appendingPathComponent("History").appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: destination)
            var record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
            record.languageIdentifier = settings.configuration?.language
            try await saveRecord(record)
            if closed {
                var cancelled = record
                cancelled.failure = "Import cancelled when the app closed. Audio retained."
                try await saveRecord(cancelled)
                return
            }
            // An import has no recording hotkey, so it never outputs automatically.
            await transcribe(record, duration: 0, output: nil)
        } catch { update(error.localizedDescription, state: 0) }
    }

}
