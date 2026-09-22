import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

actor WindowsAppController {
    struct Settings: Codable {
        var model = OpenAITranscriptionModels.gptTranscribeCatalogID
        var postProcessing: DesktopPostProcessing.Options?
        var microphoneDeviceID: String?
    }

    private struct Recording {
        let native: OpaquePointer
        let context: WindowsCaptureContext
        var record: DesktopRecordingStore.Record
        let target: JSTITextTarget?
    }

    private struct StoppedRecording {
        let record: DesktopRecordingStore.Record
        let duration: TimeInterval
        let target: JSTITextTarget?
    }

    let directory: URL
    let store: DesktopRecordingStore
    let uploadStaging: SharedMultipartUploadStaging
    var settings: Settings
    private var recording: Recording?
    private var isReady = false
    var busy = false
    var closed = false
    private var shutdownComplete = false
    var activeOperations = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    var transcript = ""
    var history: [UUID: DesktopRecordingStore.Record] = [:]
    var selectedHistoryID: UUID?
    var transcriptionTask: Task<TranscriptionResult, Error>?
    var postProcessingTask: Task<DesktopPostProcessing.Outcome, Error>?
    var microphoneWarning: String?
    var cancellationRequested = false

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
        if !DesktopTranscription.batchModels.contains(where: { $0.id == loadedSettings.model }) {
            loadedSettings.model = OpenAITranscriptionModels.gptTranscribeCatalogID
        }
        if var processing = loadedSettings.postProcessing,
           !DesktopPostProcessing.remoteModels.contains(where: { $0.id == processing.modelIdentifier }) {
            processing.mode = .disabled
            processing.modelIdentifier = ModelCatalog.defaultPostProcessingModel
            loadedSettings.postProcessing = processing
        }
        self.settings = loadedSettings
    }

    func toggle(target: JSTITextTarget?, modelIndex: Int, deviceID: String) async {
        guard isReady, !busy, !closed, DesktopTranscription.batchModels.indices.contains(modelIndex) else { return }
        selectModel(modelIndex)
        selectMicrophone(deviceID)
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        if recording != nil { await stopAndTranscribe(); return }
        do {
            guard !(try WindowsNative.apiKey(name: credentialIdentifier(for: settings.model))).isEmpty else {
                throw TranscriptionProviderError.apiKeyMissing
            }
            let id = UUID()
            let filename = id.uuidString + ".wav"
            let audio = directory.appendingPathComponent("History").appendingPathComponent(filename)
            let file = try PCMRecordingFile(url: audio)
            let record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
            do {
                // The operation remains active through every metadata write so
                // shutdown cannot return while startup is still suspended here.
                try await saveRecord(record)
                guard !closed else { throw CancellationError() }
                let context = WindowsCaptureContext(file: file) { message in
                    Task { await self.captureFailed(message, recordingID: id) }
                }
                let native = try WindowsNative.createCapture(context: context, deviceID: deviceID)
                do { try WindowsNative.checked { jsti_capture_start(native, $0, $1) } } catch {
                    withExtendedLifetime(context) { jsti_capture_destroy(native) }
                    throw error
                }
                recording = Recording(native: native, context: context, record: record, target: target)
            } catch {
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

    private func stopCapture() throws -> StoppedRecording? {
        guard let active = recording else { return nil }
        recording = nil
        defer { jsti_capture_destroy(active.native) }
        var stopFailure: Error?
        do { try WindowsNative.checked { jsti_capture_stop(active.native, $0, $1) } } catch { stopFailure = error }
        let duration = try active.context.file.finish()
        if let stopFailure { throw stopFailure }
        return StoppedRecording(
            record: active.record, duration: active.context.file.isDigitalSilence ? 0 : duration, target: active.target
        )
    }

    private func stopAndTranscribe() async {
        let pending = recording?.record
        do {
            guard let stopped = try stopCapture() else { return }
            guard stopped.duration > 0 else {
                var empty = stopped.record
                empty.failure = "No audio was captured."
                try await saveRecord(empty)
                update("No audio was captured.", state: 0)
                return
            }
            await transcribe(stopped.record, duration: stopped.duration, target: stopped.target)
        } catch {
            if var pending {
                pending.failure = error.localizedDescription
                do { try await saveRecord(pending) } catch {
                    update("Recording and history error: \(error.localizedDescription)", state: 0)
                    return
                }
            }
            update("Recording retained: \(error.localizedDescription)", state: 0)
        }
    }

    private func captureFailed(_ message: String, recordingID: UUID) async {
        guard !closed, recording?.record.id == recordingID else { return }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        var record = recording?.record
        _ = try? stopCapture()
        record?.failure = message
        do { if let record { try await saveRecord(record) } } catch {
            update("\(message) History error: \(error.localizedDescription)", state: 0)
            return
        }
        update("Recording stopped and retained: \(message)", state: 0)
    }

    func importAudio(path: String, modelIndex: Int) async {
        guard isReady, !busy, !closed, recording == nil,
              DesktopTranscription.batchModels.indices.contains(modelIndex) else { return }
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

    func close() async {
        if closed {
            if !shutdownComplete {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
            return
        }
        closed = true
        cancellationRequested = true
        transcriptionTask?.cancel()
        postProcessingTask?.cancel()
        if var record = recording?.record {
            record.failure = "Recording stopped when the app closed. Audio retained."
            do { _ = try stopCapture() } catch {
                record.failure = "\(record.failure ?? "Recording stopped.") \(error.localizedDescription)"
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
        shutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

}

extension WindowsAppController {
    func saveRecord(_ record: DesktopRecordingStore.Record) async throws {
        try await store.save(record)
        history[record.id] = record
        refreshHistory()
    }

    func refreshHistory() {
        guard !closed else { return }
        WindowsNative.history(Array(history.values).sorted { $0.createdAt > $1.createdAt }, selected: selectedHistoryID)
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
        guard let provider = DesktopTranscription.provider(for: model) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        return provider.apiKeyIdentifier
    }
    var canUseHistory: Bool { isReady && !closed && !busy && recording == nil }

    func selectedIndex() -> Int {
        DesktopTranscription.batchModels.firstIndex { $0.id == settings.model } ?? 0
    }

    func ready() async {
        defer { isReady = true }
        guard !closed else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            let recovery = try await store.recoverInterruptedRecordings()
            guard !closed, !busy, recording == nil else { return }
            let records = recovery.records
            history = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            selectedHistoryID = records.first(where: { $0.result != nil })?.id ?? records.first?.id
            transcript = selectedHistoryID.flatMap { history[$0]?.displayText } ?? ""
            refreshHistory()
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
        guard !closed, !busy, recording == nil, DesktopTranscription.batchModels.indices.contains(index) else { return }
        settings.model = DesktopTranscription.batchModels[index].id
        do {
            try JSONEncoder().encode(settings).write(
                to: directory.appendingPathComponent("settings.json"), options: .atomic
            )
            let hint = DesktopTranscription.provider(for: settings.model)?.apiKeyIdentifier
                == AzureSpeechConfiguration.credentialIdentifier
                ? " Enter Azure credentials as key:region (for example, your key followed by :uksouth)." : ""
            update("Selected \(DesktopTranscription.batchModels[index].displayName).\(hint)")
        } catch { update("Could not save settings: \(error.localizedDescription)") }
    }

    func saveKey(_ key: String, modelIndex: Int) {
        guard !closed, !busy, recording == nil else { return }
        do {
            guard DesktopTranscription.batchModels.indices.contains(modelIndex),
                  let provider = DesktopTranscription.provider(
                    for: DesktopTranscription.batchModels[modelIndex].id
                  ) else { throw DesktopTranscriptionError.unsupportedModel }
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, provider.apiKeyIdentifier == AzureSpeechConfiguration.credentialIdentifier {
                _ = try AzureSpeechConfiguration(credentials: cleaned)
            }
            try WindowsNative.saveAPIKey(cleaned, name: provider.apiKeyIdentifier)
            update(cleaned.isEmpty ? "API key removed." : "API key saved in Windows Credential Manager.")
        } catch { update(error.localizedDescription) }
    }

    func copyTranscript(identifier: String = "") {
        guard !closed else { return }
        do {
            let selected = UUID(uuidString: identifier).flatMap { history[$0]?.displayText }
            try (selected ?? transcript).withCString { text in
                try WindowsNative.checked { jsti_clipboard_write(text, $0, $1) }
            }
            update("Transcript copied.")
        } catch { update(error.localizedDescription) }
    }
}
