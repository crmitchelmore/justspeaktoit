import Foundation
import SpeakCore
import SpeakDesktop

/// Startup readiness, busy/operation bookkeeping, model selection and
/// transcript-copy actions, split out of `DesktopHostController.swift` to
/// keep that file under the pinned file-length limit.
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

    func finishBusyOperation() {
        busyOperations -= 1
        busy = busyOperations > 0
        finishOperation()
    }

    func beginBusyOperation() {
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
    package var canUseHistory: Bool { isReady && !closed && !busy && recording == nil && handsFreeRun == nil }

    package func selectedIndex() -> Int {
        DesktopHostModels.all.firstIndex { $0.id == settings.model } ?? 0
    }

    package func ready() async {
        defer { isReady = true; reconcileCapturePreparation() }
        guard !closed else { return }
        preparePlayback()
        await prepareRecordingFeedback()
        refreshModels(force: false)
        activeOperations += 1
        defer { finishOperation() }
        do {
            guard let (recovery, deletionWarning) = try await prepareReadyHistory() else { return }
            let status = try await readyStatusMessage(recovery: recovery, deletionWarning: deletionWarning)
            guard !closed else { return }
            showSelectedHistory(status: status, state: 0)
        } catch { update(error.localizedDescription, state: 0) }
    }

    /// Recovers interrupted recordings and indexes them into history. Returns
    /// `nil` (without indexing anything) when the controller stopped being
    /// ready for the result while recovery was in flight, matching `ready()`'s
    /// original silent early return.
    private func prepareReadyHistory() async throws
        -> (recovery: DesktopRecordingStore.RecoveryReport, deletionWarning: String?)? {
        var deletionWarning: String?
        do {
            try await store.resumePendingDeletions()
        } catch {
            deletionWarning = "History deletion cleanup needs attention: \(error.localizedDescription)"
        }
        let recovery = try await store.recoverInterruptedRecordings()
        guard !closed, !busy, recording == nil else { return nil }
        let records = recovery.records
        history.removeAll()
        historySearchText.removeAll()
        for record in records where history[record.id] == nil { indexHistory(record) }
        selectedHistoryID = records.first(where: { $0.result != nil })?.id ?? records.first?.id
        transcript = selectedHistoryID.flatMap { history[$0]?.displayText } ?? ""
        transcriptVariant = .processed
        refreshHistory(selectRecord: true)
        return (recovery, deletionWarning)
    }

    /// Builds the ready-status line, appending warnings about comparisons,
    /// unreadable history, the microphone and the active profile.
    private func readyStatusMessage(
        recovery: DesktopRecordingStore.RecoveryReport, deletionWarning: String?
    ) async throws -> String {
        var status = try readyStatus(savedRecordings: recovery.records.count)
        do { _ = try await loadComparisonStore() } catch {
            status += " Saved comparisons could not be opened: \(error.localizedDescription)"
        }
        if !recovery.unreadableFiles.isEmpty {
            status += " \(recovery.unreadableFiles.count) history records could not be read."
        }
        if let deletionWarning { status += " \(deletionWarning)" }
        if let microphoneWarning { status += " \(microphoneWarning)" }
        if let profileWarning { status += " \(profileWarning)" }
        return status
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
