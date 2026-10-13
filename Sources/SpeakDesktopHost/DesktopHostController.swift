import Foundation
import SpeakCore
import SpeakDesktop

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
        package var localModel: String?
        package var localUseGPU: Bool?
        /// Device-local Azure resource, under the Apple apps' key.
        package var azureSpeechResourceEndpoint: String?
        package var appearance: DesktopAppearance?
        /// Last reached registration for hosts that cannot read it back.
        package var runAtLogin: Bool?
        package var configuration: DesktopConfiguration?
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
            let known: Set<String> = [
                "model", "postProcessing", "microphoneDeviceID", "batchModel", "liveModel", "textOutput",
                "hotKey", "voiceOutput", "automationEnabled", "localModel", "localUseGPU",
                "azureSpeechResourceEndpoint", "appearance", "runAtLogin", "configuration"
            ]
            preserved = all.filter { !known.contains($0.key) }
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
        package var record: DesktopRecordingStore.Record
        package let target: Platform.InsertionTarget?
        package let live: DesktopLiveSession?
        package let profile: DesktopProfileSession
        package let textOutput: Platform.TextOutputOptions
        /// What started this session; a shortcut gesture stops only its own kind.
        package let trigger: HotKeySessionTrigger
    }

    package struct StoppedRecording {
        package let record: DesktopRecordingStore.Record
        package let duration: TimeInterval
        package let target: Platform.InsertionTarget?
        package let live: DesktopLiveSession?
        package let profile: DesktopProfileSession
        package let textOutput: Platform.TextOutputOptions
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
    package var profiles: [DictationProfile]
    var profileWarning: String?
    package var settings: Settings
    package var recording: Recording?
    package var recordingTail: (recordID: UUID, task: Task<Void, Never>)?
    private var isReady = false
    package var busy = false
    private var busyOperations = 0
    package var closed = false
    /// Set once `close()` stops waiting; later calls return it.
    var shutdownReport: DesktopHostShutdownReport?
    /// How long `close()` waits in all for cancelled work to end.
    package nonisolated let shutdownGrace: Duration
    package var activeOperations = 0
    var operationWaiters: [CheckedContinuation<Void, Never>] = []
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    package var transcript = ""
    package var hotKeySession = DesktopHostHotKeySessionState()
    package var readAloudState = Platform.makeReadAloudState()
    /// The one History Play or Read aloud request that may still start audio or report.
    package var playbackRequests = DesktopPlaybackRequests()
    package var history: [UUID: DesktopRecordingStore.Record] = [:]
    /// Folded search text per record, refreshed only when a record is saved so
    /// each keystroke filters cached strings instead of re-normalising transcripts.
    package var historySearchText: [UUID: String] = [:]
    var historyQuery = ""
    package var selectedHistoryID: UUID?
    package var transcriptVariant: DesktopTranscriptVariant = .processed
    var transcriptionTask: Task<TranscriptionResult, Error>?
    var postProcessingTask: Task<DesktopPostProcessing.Outcome, Error>?
    package var microphoneWarning: String?
    var cancellationRequested = false
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

    package init(
        directory: URL, effects: any DesktopHostEffects<Platform>, shutdownGrace: Duration = DesktopHostShutdown.grace
    ) throws {
        self.directory = directory
        self.effects = effects
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
        modelCatalog = try Self.prepareModelCatalog(directory: directory, settings: &loadedSettings)
        if let processing = loadedSettings.postProcessing {
            loadedSettings.postProcessing = DesktopPostProcessing.migrated(processing)
        }
        self.settings = loadedSettings
    }

    /// `textOutput` was read in settings order at the Record event, so a later
    /// Apply cannot change how this recording is output.
    package func toggle(
        target: Platform.InsertionTarget?, modelIndex: Int, deviceID: String,
        targetExecutablePath: String?, textOutput: Platform.TextOutputOptions,
        trigger: HotKeySessionTrigger = .other
    ) async {
        guard isReady, !busy, !closed, DesktopHostModels.all.indices.contains(modelIndex) else { return }
        cancelOutput()
        let selected = selectModel(modelIndex)
        selectMicrophone(deviceID)
        beginBusyOperation()
        defer { finishBusyOperation() }
        if recording != nil { await stopAndTranscribe(); return }
        // Never record with a model other than the one chosen; why it could
        // not be saved stays shown.
        guard selected else { return }
        do {
            // Wait for acknowledged silence, while slow decoder release stays
            // off this actor. Busy prevents another capture during suspension.
            try await playback.stopAndWait()
            guard !closed else { return }
            let profile = resolvedProfile(executablePath: targetExecutablePath)
            if let limitation = profile.blockingLimitation { throw DesktopHostError(message: limitation.message) }
            try await startRecording(
                target: target, deviceID: deviceID, profile: profile, textOutput: textOutput, trigger: trigger
            )
        } catch {
            update(error.localizedDescription, state: 0)
            failHUDStart(error.localizedDescription)
        }
    }

    /// Self-test only: startup without model discovery, which could reach the
    /// network with a real saved credential.
    package func markReadyForSelfTest() { isReady = true }
}

extension DesktopHostController {
    func captureFailed(_ message: String, recordingID: UUID) async {
        guard !closed, recording?.record.id == recordingID else { return }
        beginBusyOperation()
        defer { finishBusyOperation() }
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
              !DesktopHostModels.isLive(DesktopHostModels.all[modelIndex].id) else { return }
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

extension DesktopHostController {
    package func saveRecord(_ record: DesktopRecordingStore.Record) async throws {
        try await store.save(record)
        indexHistory(record)
        refreshHistory()
        cloudSync.historyChanged?()
    }

    package func finishOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishBusyOperation() {
        busyOperations -= 1
        busy = busyOperations > 0
        finishOperation()
    }

    private func beginBusyOperation() {
        busyOperations += 1
        busy = true
        activeOperations += 1
    }

    package func update(_ status: String, transcript: String? = nil, state: Int32 = -1) {
        guard !closed else { return }
        Platform.update(status, transcript: transcript, state: state)
    }

    package func credentialIdentifier(for model: String) throws -> String {
        guard let provider = DesktopHostModels.provider(for: model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        return provider.apiKeyIdentifier
    }
    package var canUseHistory: Bool { isReady && !closed && !busy && recording == nil }

    package func selectedIndex() -> Int {
        DesktopHostModels.all.firstIndex { $0.id == settings.model } ?? 0
    }

    package func ready() async {
        defer { isReady = true }
        guard !closed else { return }
        preparePlayback()
        refreshModels(force: false)
        activeOperations += 1
        defer { finishOperation() }
        do {
            let recovery = try await store.recoverInterruptedRecordings()
            guard !closed, !busy, recording == nil else { return }
            let records = recovery.records
            history.removeAll()
            historySearchText.removeAll()
            for record in records where history[record.id] == nil { indexHistory(record) }
            selectedHistoryID = records.first(where: { $0.result != nil })?.id ?? records.first?.id
            transcript = selectedHistoryID.flatMap { history[$0]?.displayText } ?? ""
            transcriptVariant = .processed
            refreshHistory(selectRecord: true)
            var status = try readyStatus(savedRecordings: records.count)
            if !recovery.unreadableFiles.isEmpty {
                status += " \(recovery.unreadableFiles.count) history records could not be read."
            }
            if let microphoneWarning { status += " \(microphoneWarning)" }
            if let profileWarning { status += " \(profileWarning)" }
            showSelectedHistory(status: status, state: 0)
        } catch { update(error.localizedDescription, state: 0) }
    }

    /// Uses the model once it is saved; an unchanged choice writes nothing.
    /// Returns false when the choice is refused or cannot be saved, and the
    /// previous model stays in use.
    @discardableResult
    package func selectModel(_ index: Int) -> Bool {
        guard !closed, !busy, recording == nil, DesktopHostModels.all.indices.contains(index) else { return false }
        let model = DesktopHostModels.all[index]
        var chosen = settings
        chosen.model = model.id
        Self.rememberModelSlot(in: &chosen)
        if chosen.model != settings.model || chosen.batchModel != settings.batchModel
            || chosen.liveModel != settings.liveModel || chosen.localModel != settings.localModel {
            do {
                try effects.writeSettings(
                    JSONEncoder().encode(chosen), to: directory.appendingPathComponent("settings.json")
                )
            } catch {
                update("Could not save settings: \(error.localizedDescription)")
                return false
            }
            let switched = chosen.model != settings.model
            settings = chosen
            if switched { publishModelCatalog(modelCatalog.snapshot) }
        }
        let hint = DesktopHostModels.provider(for: model.id)?.apiKeyIdentifier
            == AzureSpeechConfiguration.credentialIdentifier
            ? DesktopHostAzureResource.selectionHint(for: model.id) : ""
        update("Selected \(model.displayName).\(hint)")
        return true
    }

    /// Text and version are the immutable display snapshot from the Copy click;
    /// a later selection or retry cannot replace the content this action uses.
    package func copyTranscript(_ text: String, variant: DesktopTranscriptVariant? = nil) {
        guard !closed else { return }
        guard !text.isEmpty else { update("There is no transcript to copy."); return }
        do {
            try Platform.copyToClipboard(text)
            update(variant == .original
                ? "Original transcript copied." : "Transcript copied.")
        } catch { update(error.localizedDescription) }
    }
}
