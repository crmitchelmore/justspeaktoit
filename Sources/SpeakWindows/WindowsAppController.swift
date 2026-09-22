import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

actor WindowsAppController {
    private struct Settings: Codable {
        var model = OpenAITranscriptionModels.gptTranscribeCatalogID
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

    private let directory: URL
    private let store: DesktopRecordingStore
    private var settings: Settings
    private var recording: Recording?
    private var busy = false
    private var closed = false
    private var shutdownComplete = false
    private var activeOperations = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcript = ""
    private var transcriptionTask: Task<TranscriptionResult, Error>?

    init(directory: URL) throws {
        self.directory = directory
        self.store = try DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
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
        self.settings = loadedSettings
    }

    func toggle(target: JSTITextTarget?) async {
        guard !busy, !closed else { return }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        if recording != nil { await stopAndTranscribe(); return }
        do {
            guard !(try WindowsNative.apiKey()).isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
            let id = UUID()
            let filename = id.uuidString + ".wav"
            let audio = directory.appendingPathComponent("History").appendingPathComponent(filename)
            let file = try PCMRecordingFile(url: audio)
            let record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
            do {
                // The operation remains active through every metadata write so
                // shutdown cannot return while startup is still suspended here.
                try await store.save(record)
                guard !closed else { throw CancellationError() }
                let context = WindowsCaptureContext(file: file) { message in
                    Task { await self.captureFailed(message, recordingID: id) }
                }
                guard let native = jsti_capture_create(
                    captureAudio, captureError, Unmanaged.passUnretained(context).toOpaque()
                ) else { throw WindowsNativeError(message: "Could not create microphone capture.") }
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
                do { try await store.save(failed) } catch {
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
                try await store.save(empty)
                update("No audio was captured.", state: 0)
                return
            }
            await transcribe(stopped.record, duration: stopped.duration, target: stopped.target)
        } catch {
            if var pending {
                pending.failure = error.localizedDescription
                do { try await store.save(pending) } catch {
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
        do { if let record { try await store.save(record) } } catch {
            update("\(message) History error: \(error.localizedDescription)", state: 0)
            return
        }
        update("Recording stopped and retained: \(message)", state: 0)
    }

    func importAudio(path: String) async {
        guard !busy, !closed, recording == nil else { return }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        do {
            guard !(try WindowsNative.apiKey()).isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
            let source = URL(fileURLWithPath: path)
            let id = UUID()
            let filename = id.uuidString + "." + source.pathExtension
            let destination = directory.appendingPathComponent("History").appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: destination)
            let record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: settings.model)
            try await store.save(record)
            if closed {
                var cancelled = record
                cancelled.failure = "Import cancelled when the app closed. Audio retained."
                try await store.save(cancelled)
                return
            }
            await transcribe(record, duration: 0, target: nil)
        } catch { update(error.localizedDescription, state: 0) }
    }

    private func transcribe(
        _ original: DesktopRecordingStore.Record, duration: TimeInterval, target: JSTITextTarget?
    ) async {
        var record = original
        do {
            guard !closed else { throw CancellationError() }
            let key = try WindowsNative.apiKey()
            let audio = directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename)
            let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25_000_000 else {
                throw WindowsNativeError(
                    message: "Audio exceeds the provider's 25 MB upload limit. The recording is saved."
                )
            }
            update("Transcribing… Your recording is saved locally.", state: 2)
            let model = record.modelIdentifier
            let task = Task {
                try Task.checkCancellation()
                return try await DesktopTranscription.transcribe(
                    audioURL: audio, model: model, apiKey: key, duration: duration
                )
            }
            transcriptionTask = task
            defer { transcriptionTask = nil }
            let result = try await task.value
            record.result = result
            record.failure = nil
            try await store.save(record)
            // A response already received is still durably saved during shutdown,
            // but closing must never insert text or update a destroyed window.
            guard !closed else { return }
            transcript = result.text
            var status = "Saved to History. Select Copy to use the transcript."
            if var target, !transcript.isEmpty, !closed {
                do {
                    try transcript.withCString { text in
                        try WindowsNative.checked { jsti_target_insert_text(&target, text, $0, $1) }
                    }
                    status = "Inserted into the original text field and saved to History."
                } catch {
                    status = "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
                }
            }
            update(status, transcript: transcript, state: 0)
        } catch {
            record.failure = error.localizedDescription
            do { try await store.save(record) } catch {
                update("History could not be saved: \(error.localizedDescription)", state: 0)
                return
            }
            update("Audio retained in History. \(error.localizedDescription)", state: 0)
        }
    }

    func close() async {
        if closed {
            if !shutdownComplete {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
            return
        }
        closed = true
        transcriptionTask?.cancel()
        if var record = recording?.record {
            record.failure = "Recording stopped when the app closed. Audio retained."
            do { _ = try stopCapture() } catch {
                record.failure = "\(record.failure ?? "Recording stopped.") \(error.localizedDescription)"
            }
            do { try await store.save(record) } catch {
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

    private func finishOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func update(_ status: String, transcript: String? = nil, state: Int32 = -1) {
        guard !closed else { return }
        WindowsNative.update(status, transcript: transcript, state: state)
    }
}

extension WindowsAppController {
    func selectedIndex() -> Int {
        DesktopTranscription.batchModels.firstIndex { $0.id == settings.model } ?? 0
    }

    func ready() async {
        guard !closed else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            let recovery = try await store.recoverInterruptedRecordings()
            guard !closed, !busy, recording == nil else { return }
            let records = recovery.records
            transcript = records.first(where: { $0.result != nil })?.result?.text ?? ""
            let key = try WindowsNative.apiKey()
            var status = key.isEmpty ? "Enter and save your OpenAI API key to record or import audio."
                : "Ready. Ctrl+Alt+Space starts or stops recording. \(records.count) saved recordings."
            if !recovery.unreadableFiles.isEmpty {
                status += " \(recovery.unreadableFiles.count) history records could not be read."
            }
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
        } catch { update("Could not save settings: \(error.localizedDescription)") }
    }

    func saveKey(_ key: String) {
        guard !closed, !busy, recording == nil else { return }
        do {
            try WindowsNative.saveAPIKey(key)
            update(key.isEmpty ? "API key removed." : "API key saved in Windows Credential Manager.")
        } catch { update(error.localizedDescription) }
    }

    func copyTranscript() {
        guard !closed else { return }
        do {
            try transcript.withCString { text in
                try WindowsNative.checked { jsti_clipboard_write(text, $0, $1) }
            }
            update("Transcript copied.")
        } catch { update(error.localizedDescription) }
    }
}
