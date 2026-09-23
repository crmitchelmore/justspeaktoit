import Foundation
import SpeakCore
import SpeakDesktop

package actor DesktopHostController<Platform: DesktopHostPlatform> {
    package struct Settings: Codable {
        var model = ModelCatalog.defaultBatchTranscriptionModel
        var postProcessing: DesktopPostProcessing.Options?
        var microphoneDeviceID: String?
        var batchModel: String?
        var liveModel: String?
        // Edited in the Text output dialog. Absent or unknown keys keep the
        // smart insert-at-cursor default with clipboard restoration.
        package var textOutput: Platform.TextOutputOptions?
        // Keyboard shortcut dialog; absent keeps Ctrl+Alt+Space, press-to-toggle.
        package var hotKey: Platform.HotKeySettings?
    }

    /// Target, profile and text output are fixed when recording starts; a
    /// later settings change applies only to later recordings.
    package struct Recording {
        let capture: any DesktopRecordingCapture
        let context: DesktopCaptureContext
        var record: DesktopRecordingStore.Record
        let target: Platform.InsertionTarget?
        let live: DesktopLiveSession?
        let profile: DesktopProfileSession
        let textOutput: Platform.TextOutputOptions
        /// What started this session; a shortcut gesture stops only its own kind.
        package let trigger: HotKeySessionTrigger
    }

    package struct StoppedRecording {
        let record: DesktopRecordingStore.Record
        let duration: TimeInterval
        let target: Platform.InsertionTarget?
        let live: DesktopLiveSession?
        let profile: DesktopProfileSession
        let textOutput: Platform.TextOutputOptions
        var output: DesktopHostRecordingOutput<Platform> { .init(options: textOutput, target: target) }
    }

    package let directory: URL
    package let effects: any DesktopHostEffects<Platform>
    let store: DesktopRecordingStore
    let uploadStaging: SharedMultipartUploadStaging
    let modelCatalog: OpenRouterAudioCatalogStore
    var modelDiscoveryTask: Task<Void, Never>?
    var modelCatalogRevision: UInt64 = 0
    let profileStore: DesktopDictationProfileStore
    package var profiles: [DictationProfile]
    var profileWarning: String?
    package var settings: Settings
    package var recording: Recording?
    private var isReady = false
    package var busy = false
    package var closed = false
    private var shutdownComplete = false
    var activeOperations = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    var transcript = ""
    /// Shortcut gesture bookkeeping, in the monotonic clock of recognition.
    package var lastHotKeyDoubleTap: TimeInterval = -.infinity
    package var hotKeyStartsAfter: TimeInterval = 0
    package var history: [UUID: DesktopRecordingStore.Record] = [:]
    /// Folded search text per record, refreshed only when a record is saved so
    /// each keystroke filters cached strings instead of re-normalising transcripts.
    var historySearchText: [UUID: String] = [:]
    var historyQuery = ""
    package var selectedHistoryID: UUID?
    var transcriptVariant: DesktopTranscriptVariant = .processed
    var transcriptionTask: Task<TranscriptionResult, Error>?
    var postProcessingTask: Task<DesktopPostProcessing.Outcome, Error>?
    var microphoneWarning: String?
    var cancellationRequested = false
    var liveUpdates: Task<Void, Never>?
    var liveFinalisation: DesktopLiveSession?
    package var outputSlot = DesktopHostOutputState<Platform>()
    /// At most one audible native History playback; its status presenter is
    /// installed by preparePlayback once this actor exists.
    let playback = Platform.makePlayback()

    package init(directory: URL, effects: any DesktopHostEffects<Platform>) throws {
        self.directory = directory
        self.effects = effects
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
        selectModel(modelIndex)
        selectMicrophone(deviceID)
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        if recording != nil { await stopAndTranscribe(); return }
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
        } catch { update(error.localizedDescription, state: 0) }
    }

    /// Self-test only: startup without model discovery, which could reach the
    /// network with a real saved credential.
    package func markReadyForSelfTest() { isReady = true }
}

extension DesktopHostController {
    private func stopAndTranscribe() async {
        let pending = recording?.record
        let live = recording?.live
        do {
            guard let stopped = try stopCapture() else { return }
            guard stopped.duration > 0 else {
                stopped.live?.cancel()
                var empty = stopped.record
                empty.failure = "No audio was captured."
                try await saveRecord(empty)
                update("No audio was captured.", state: 0)
                return
            }
            if let live = stopped.live {
                await finishLive(stopped, session: live)
            } else {
                await transcribe(
                    stopped.record, duration: stopped.duration, output: stopped.output, profile: stopped.profile
                )
            }
        } catch {
            if var pending {
                pending.failure = error.localizedDescription
                if let live { pending.result = liveResult(live.cancel().text, record: pending, duration: 0) }
                do { try await saveRecord(pending) } catch {
                    update("Recording and history error: \(error.localizedDescription)", state: 0)
                    return
                }
                present(pending, output: nil)
                return
            }
            update("Recording retained: \(error.localizedDescription)", state: 0)
        }
    }

    func captureFailed(_ message: String, recordingID: UUID) async {
        guard !closed, recording?.record.id == recordingID else { return }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        var record = recording?.record
        let live = recording?.live
        let stopped = try? stopCapture()
        if let live, var partial = record {
            let snapshot = live.cancel()
            partial.result = liveResult(snapshot.text, record: partial, duration: stopped?.duration ?? 0)
            record = partial
        }
        record?.failure = message
        do { if let record { try await saveRecord(record) } } catch {
            update("\(message) History error: \(error.localizedDescription)", state: 0)
            return
        }
        if let record { present(record, output: nil) } else {
            update("Recording stopped and retained: \(message)", state: 0)
        }
    }

    package func importAudio(path: String, modelIndex: Int) async {
        guard isReady, !busy, !closed, recording == nil,
              DesktopHostModels.all.indices.contains(modelIndex),
              !DesktopHostModels.isLive(DesktopHostModels.all[modelIndex].id) else { return }
        cancelOutput()
        selectModel(modelIndex)
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        do {
            try await playback.stopAndWait()
            guard !closed else { return }
            guard !(try effects.apiKey(name: credentialIdentifier(for: settings.model))).isEmpty else {
                throw TranscriptionProviderError.apiKeyMissing
            }
            let source = URL(fileURLWithPath: path)
            try DesktopHostImport.validate(source)
            let id = UUID()
            let filename = id.uuidString + "." + source.pathExtension
            let destination = directory.appendingPathComponent("History").appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: destination)
            let record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
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
    package func close() async {
        if closed {
            if !shutdownComplete {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
            return
        }
        closed = true
        modelDiscoveryTask?.cancel()
        cancelOutput()
        cancellationRequested = true
        transcriptionTask?.cancel()
        postProcessingTask?.cancel()
        liveFinalisation?.cancel()
        if var record = recording?.record {
            let live = recording?.live
            record.failure = "Recording stopped when the app closed. Audio retained."
            var duration: TimeInterval = 0
            do { duration = try stopCapture()?.duration ?? 0 } catch {
                record.failure = "\(record.failure ?? "Recording stopped.") \(error.localizedDescription)"
            }
            if let live {
                record.result = liveResult(live.cancel().text, record: record, duration: duration)
            }
            do { try await saveRecord(record) } catch {
                FileHandle.standardError.write(Data("Could not persist recording on close.\n".utf8))
            }
        }
        // Includes admitted opens and every background release attempt.
        do { try await playback.close() } catch {
            FileHandle.standardError.write(Data("Playback cleanup failed: \(error.localizedDescription)\n".utf8))
        }
        // The network task alone is insufficient: its owner must also finish
        // success/failure persistence and release native/file resources.
        if activeOperations > 0 {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
        await modelDiscoveryTask?.value
        modelDiscoveryTask = nil
        shutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

}

extension DesktopHostController {
    func saveRecord(_ record: DesktopRecordingStore.Record) async throws {
        try await store.save(record)
        indexHistory(record)
        refreshHistory()
    }

    func finishOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    package func update(_ status: String, transcript: String? = nil, state: Int32 = -1) {
        guard !closed else { return }
        Platform.update(status, transcript: transcript, state: state)
    }

    func credentialIdentifier(for model: String) throws -> String {
        guard let provider = DesktopHostModels.provider(for: model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        return provider.apiKeyIdentifier
    }
    var canUseHistory: Bool { isReady && !closed && !busy && recording == nil }

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
            let key = try Platform.apiKey(name: credentialIdentifier(for: settings.model))
            var status = key.isEmpty ? "Enter and save the selected provider’s API key to record or import audio."
                : "Ready. \(Platform.readyHint(hotKeySettings())) \(records.count) saved recordings."
            if !recovery.unreadableFiles.isEmpty {
                status += " \(recovery.unreadableFiles.count) history records could not be read."
            }
            if let microphoneWarning { status += " \(microphoneWarning)" }
            if let profileWarning { status += " \(profileWarning)" }
            showSelectedHistory(status: status, state: 0)
        } catch { update(error.localizedDescription, state: 0) }
    }

    package func selectModel(_ index: Int) {
        guard !closed, !busy, recording == nil, DesktopHostModels.all.indices.contains(index) else { return }
        let changed = settings.model != DesktopHostModels.all[index].id
        settings.model = DesktopHostModels.all[index].id
        if DesktopHostModels.isLive(settings.model) { settings.liveModel = settings.model } else {
            settings.batchModel = settings.model
        }
        do {
            try JSONEncoder().encode(settings).write(
                to: directory.appendingPathComponent("settings.json"), options: .atomic
            )
            let hint = DesktopTranscription.provider(for: settings.model)?.apiKeyIdentifier
                == AzureSpeechConfiguration.credentialIdentifier
                ? " Enter Azure credentials as key:region (for example, your key followed by :uksouth)." : ""
            if changed { publishModelCatalog(modelCatalog.snapshot) }
            update("Selected \(DesktopHostModels.all[index].displayName).\(hint)")
        } catch { update("Could not save settings: \(error.localizedDescription)") }
    }

    package func saveKey(_ key: String, modelIndex: Int) {
        guard !closed, !busy, recording == nil else { return }
        do {
            guard DesktopHostModels.all.indices.contains(modelIndex),
                  let provider = DesktopHostModels.provider(
                    for: DesktopHostModels.all[modelIndex].id
                  ) else { throw DesktopTranscriptionError.unsupportedModel }
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, provider.apiKeyIdentifier == AzureSpeechConfiguration.credentialIdentifier {
                _ = try AzureSpeechConfiguration(credentials: cleaned)
            }
            try Platform.saveAPIKey(cleaned, name: provider.apiKeyIdentifier)
            if provider.id == OpenRouterService.providerID { refreshModels(force: true) }
            update(cleaned.isEmpty ? "API key removed." : "API key saved in \(Platform.credentialStoreName).")
        } catch { update(error.localizedDescription) }
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
