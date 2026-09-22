import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

actor WindowsAppController {
    struct Settings: Codable {
        var model = ModelCatalog.defaultBatchTranscriptionModel
        var postProcessing: DesktopPostProcessing.Options?
        var microphoneDeviceID: String?
        var batchModel: String?
        var liveModel: String?
        // No settings UI yet; edited by hand in settings.json. Absent keys keep
        // the smart insert-at-cursor default with clipboard restoration.
        var textOutput: WindowsTextOutputOptions?
    }

    struct Recording {
        let native: OpaquePointer
        let context: WindowsCaptureContext
        var record: DesktopRecordingStore.Record
        let target: WindowsInsertionTarget?
        let live: DesktopLiveSession?
    }

    struct StoppedRecording {
        let record: DesktopRecordingStore.Record
        let duration: TimeInterval
        let target: WindowsInsertionTarget?
        let live: DesktopLiveSession?
    }

    let directory: URL
    let store: DesktopRecordingStore
    let uploadStaging: SharedMultipartUploadStaging
    let modelCatalog: OpenRouterAudioCatalogStore
    var modelDiscoveryTask: Task<Void, Never>?
    var modelCatalogRevision: UInt64 = 0
    var settings: Settings
    var recording: Recording?
    private var isReady = false
    var busy = false
    var closed = false
    private var shutdownComplete = false
    var activeOperations = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    var transcript = ""
    var history: [UUID: DesktopRecordingStore.Record] = [:]
    /// Folded search text per record, refreshed only when a record is saved so
    /// each keystroke filters cached strings instead of re-normalising transcripts.
    var historySearchText: [UUID: String] = [:]
    var historyQuery = ""
    var selectedHistoryID: UUID?
    var transcriptVariant: DesktopTranscriptVariant = .processed
    var transcriptionTask: Task<TranscriptionResult, Error>?
    var postProcessingTask: Task<DesktopPostProcessing.Outcome, Error>?
    var microphoneWarning: String?
    var cancellationRequested = false
    var liveUpdates: Task<Void, Never>?
    var liveFinalisation: DesktopLiveSession?

    init(directory: URL) throws {
        self.directory = directory
        self.store = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
        self.uploadStaging = WindowsNative.uploadStaging(directory: directory.appendingPathComponent("Uploads"))
        let settingsURL = directory.appendingPathComponent("settings.json")
        var loadedSettings: Settings
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            loadedSettings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
        } else {
            loadedSettings = Settings()
        }
        modelCatalog = try Self.prepareModelCatalog(directory: directory, settings: &loadedSettings)
        if var processing = loadedSettings.postProcessing,
           !DesktopPostProcessing.remoteModels.contains(where: { $0.id == processing.modelIdentifier }) {
            processing.mode = .disabled
            processing.modelIdentifier = ModelCatalog.defaultPostProcessingModel
            loadedSettings.postProcessing = processing
        }
        self.settings = loadedSettings
    }

    func toggle(target: WindowsInsertionTarget?, modelIndex: Int, deviceID: String) async {
        guard isReady, !busy, !closed, WindowsModels.all.indices.contains(modelIndex) else { return }
        selectModel(modelIndex)
        selectMicrophone(deviceID)
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        if recording != nil { await stopAndTranscribe(); return }
        do {
            let key = try WindowsNative.apiKey(name: credentialIdentifier(for: settings.model))
            guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
            let id = UUID()
            let filename = id.uuidString + ".wav"
            let audio = directory.appendingPathComponent("History").appendingPathComponent(filename)
            let rate = DesktopLiveTranscription.route(forID: settings.model)?.sampleRate ?? PCMRecordingFile.sampleRate
            let file = try PCMRecordingFile(url: audio, sampleRate: rate)
            let record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
            var live: DesktopLiveSession?
            do {
                // The operation remains active through every metadata write so
                // shutdown cannot return while startup is still suspended here.
                try await saveRecord(record)
                guard !closed else { throw CancellationError() }
                live = makeLiveSession(model: settings.model, key: key, id: id)
                live?.start()
                let context = WindowsCaptureContext(file: file, live: live) { message in
                    Task { await self.captureFailed(message, recordingID: id) }
                }
                let native = try WindowsNative.createCapture(context: context, deviceID: deviceID, sampleRate: rate)
                do { try WindowsNative.checked { jsti_capture_start(native, $0, $1) } } catch {
                    withExtendedLifetime(context) { jsti_capture_destroy(native) }
                    throw error
                }
                recording = Recording(native: native, context: context, record: record, target: target, live: live)
                if let live { monitorLive(live) }
            } catch {
                live?.cancel()
                // Finalize the WAV even if history creation or native allocation
                // failed before capture started. finish closes the file on error.
                var failed = record
                let startupFailure = error
                failed.failure = closed ? "Recording cancelled when the app closed. Audio retained."
                    : startupFailure.localizedDescription
                do { _ = try file.finish() } catch {
                    failed.failure = "\(failed.failure ?? "Recording failed.") " +
                        "Audio finalization failed: \(error.localizedDescription)"
                }
                do { try await saveRecord(failed) } catch {
                    throw WindowsNativeError(message: "\(failed.failure ?? "Recording failed.") " +
                        "History could not be saved: \(error.localizedDescription)")
                }
                throw startupFailure
            }
            update("Recording… Ctrl+Alt+Space to finish.", state: 1)
        } catch { update(error.localizedDescription, state: 0) }
    }

    func stopCapture() throws -> StoppedRecording? {
        guard let active = recording else { return nil }
        recording = nil
        liveUpdates?.cancel()
        liveUpdates = nil
        defer { jsti_capture_destroy(active.native) }
        var stopFailure: Error?
        do { try WindowsNative.checked { jsti_capture_stop(active.native, $0, $1) } } catch { stopFailure = error }
        let duration: TimeInterval
        do { duration = try active.context.file.finish() } catch { active.live?.cancel(); throw error }
        if let stopFailure { active.live?.cancel(); throw stopFailure }
        return StoppedRecording(
            record: active.record, duration: active.context.file.isDigitalSilence ? 0 : duration,
            target: active.target, live: active.live
        )
    }

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
            } else { await transcribe(stopped.record, duration: stopped.duration, target: stopped.target) }
        } catch {
            if var pending {
                pending.failure = error.localizedDescription
                if let live { pending.result = liveResult(live.cancel().text, record: pending, duration: 0) }
                do { try await saveRecord(pending) } catch {
                    update("Recording and history error: \(error.localizedDescription)", state: 0)
                    return
                }
                present(pending, target: nil)
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
        if let record { present(record, target: nil) } else {
            update("Recording stopped and retained: \(message)", state: 0)
        }
    }

    func importAudio(path: String, modelIndex: Int) async {
        guard isReady, !busy, !closed, recording == nil,
              WindowsModels.all.indices.contains(modelIndex),
              !WindowsModels.isLive(WindowsModels.all[modelIndex].id) else { return }
        selectModel(modelIndex)
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        do {
            guard !(try WindowsNative.apiKey(name: credentialIdentifier(for: settings.model))).isEmpty else {
                throw TranscriptionProviderError.apiKeyMissing
            }
            let source = URL(fileURLWithPath: path)
            try WindowsNative.validateImport(source)
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
            await transcribe(record, duration: 0, target: nil)
        } catch { update(error.localizedDescription, state: 0) }
    }

}

extension WindowsAppController {
    func close() async {
        if closed {
            if !shutdownComplete {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
            return
        }
        closed = true
        modelDiscoveryTask?.cancel()
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

extension WindowsAppController {
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

    func update(_ status: String, transcript: String? = nil, state: Int32 = -1) {
        guard !closed else { return }
        WindowsNative.update(status, transcript: transcript, state: state)
    }

    func credentialIdentifier(for model: String) throws -> String {
        guard let provider = WindowsModels.provider(for: model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        return provider.apiKeyIdentifier
    }
    var canUseHistory: Bool { isReady && !closed && !busy && recording == nil }

    func selectedIndex() -> Int {
        WindowsModels.all.firstIndex { $0.id == settings.model } ?? 0
    }

    func ready() async {
        defer { isReady = true }
        guard !closed else { return }
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
            refreshHistory()
            if let id = selectedHistoryID, let record = history[id] { showTranscriptVariant(.processed, for: record) }
            let key = try WindowsNative.apiKey(name: credentialIdentifier(for: settings.model))
            var status = key.isEmpty ? "Enter and save the selected provider’s API key to record or import audio."
                : "Ready. Ctrl+Alt+Space starts or stops recording. \(records.count) saved recordings."
            if !recovery.unreadableFiles.isEmpty {
                status += " \(recovery.unreadableFiles.count) history records could not be read."
            }
            if let microphoneWarning { status += " \(microphoneWarning)" }
            update(status, transcript: transcript, state: 0)
        } catch { update(error.localizedDescription, state: 0) }
    }

    func selectModel(_ index: Int) {
        guard !closed, !busy, recording == nil, WindowsModels.all.indices.contains(index) else { return }
        let changed = settings.model != WindowsModels.all[index].id
        settings.model = WindowsModels.all[index].id
        if WindowsModels.isLive(settings.model) { settings.liveModel = settings.model } else {
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
            update("Selected \(WindowsModels.all[index].displayName).\(hint)")
        } catch { update("Could not save settings: \(error.localizedDescription)") }
    }

    func saveKey(_ key: String, modelIndex: Int) {
        guard !closed, !busy, recording == nil else { return }
        do {
            guard WindowsModels.all.indices.contains(modelIndex),
                  let provider = WindowsModels.provider(
                    for: WindowsModels.all[modelIndex].id
                  ) else { throw DesktopTranscriptionError.unsupportedModel }
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, provider.apiKeyIdentifier == AzureSpeechConfiguration.credentialIdentifier {
                _ = try AzureSpeechConfiguration(credentials: cleaned)
            }
            try WindowsNative.saveAPIKey(cleaned, name: provider.apiKeyIdentifier)
            if provider.id == OpenRouterService.providerID { refreshModels(force: true) }
            update(cleaned.isEmpty ? "API key removed." : "API key saved in Windows Credential Manager.")
        } catch { update(error.localizedDescription) }
    }

    /// `variant` is the version the window displayed when Copy was pressed,
    /// captured with the record ID; a later selection change cannot redirect it.
    func copyTranscript(identifier: String = "", variant: DesktopTranscriptVariant? = nil) {
        guard !closed else { return }
        let record = UUID(uuidString: identifier).flatMap { history[$0] }
        let chosen = variant ?? .processed
        let text = record.map { $0.text(for: chosen) ?? "" } ?? transcript
        guard !text.isEmpty else { update("There is no transcript to copy."); return }
        do {
            try text.withCString { text in
                try WindowsNative.checked { jsti_clipboard_write(text, $0, $1) }
            }
            update(record?.hasTranscriptVariants == true && chosen == .original
                ? "Original transcript copied." : "Transcript copied.")
        } catch { update(error.localizedDescription) }
    }
}
