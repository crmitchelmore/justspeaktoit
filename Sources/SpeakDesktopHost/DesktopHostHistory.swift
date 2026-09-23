import Foundation
import SpeakDesktop

extension DesktopHostController {
    func indexHistory(_ record: DesktopRecordingStore.Record) {
        history[record.id] = record
        historySearchText[record.id] = DesktopHistorySearch.searchText(for: record)
    }

    /// Records matching the current search, newest first. Filtering changes
    /// only which rows are shown; records and transcripts are never modified.
    func visibleHistory() -> [DesktopRecordingStore.Record] {
        DesktopHistorySearch.filter(Array(history.values), query: historyQuery) { record in
            historySearchText[record.id] ?? DesktopHistorySearch.searchText(for: record)
        }
    }

    func refreshHistory(selectRecord: Bool = false) {
        guard !closed else { return }
        let visible = visibleHistory()
        if let selected = selectedHistoryID, !visible.contains(where: { $0.id == selected }) {
            // The displayed record no longer matches the search. Drop the stale
            // text and action target rather than acting on a hidden record.
            selectedHistoryID = nil
            transcript = ""
            transcriptVariant = .processed
            playback.stop()
            Platform.history(visible, selected: nil, selectRecord: selectRecord)
            Platform.transcriptVariant(nil, for: nil, switchable: false)
            update(
                "The selected recording is hidden by this search. Clear the search or choose a matching recording.",
                transcript: ""
            )
            return
        }
        Platform.history(visible, selected: selectedHistoryID, selectRecord: selectRecord)
    }

    /// Startup renders the restored selection through the same record-bound
    /// path as later selections, while an empty History can display global text.
    func showSelectedHistory(status: String, state: Int32) {
        if let id = selectedHistoryID, let record = history[id] {
            Platform.recordingState(state)
            Platform.historyPresentation(record, variant: transcriptVariant, status: status)
        } else {
            update(status, transcript: transcript, state: state)
        }
    }

    package func selectHistory(_ identifier: String) {
        guard canUseHistory, let id = UUID(uuidString: identifier),
              let record = history[id], isVisible(id) else { return }
        // A different record is displayed: the previous record's playback ends
        // and its late progress reports are rejected by the record-bound window.
        playback.stop(unless: id)
        selectedHistoryID = id
        transcript = record.text(for: .processed) ?? ""
        let status = record.failure ?? record.postProcessingFailure.map { "Post-processing failed: \($0)" }
            ?? (record.hasTranscriptVariants
                ? "Saved transcript. Transcript version switches between the processed and original text."
                : "Saved transcript. Retry uses this recording’s original model.")
        transcriptVariant = .processed
        Platform.historyPresentation(record, variant: .processed, status: status + profileContext(record))
    }

    /// A selection event for a record that a newer search has already hidden
    /// is stale; honouring it would display text for a row that is not shown.
    func isVisible(_ id: UUID) -> Bool {
        guard let record = history[id] else { return false }
        let searchText = historySearchText[id] ?? DesktopHistorySearch.searchText(for: record)
        return DesktopHistorySearch.matches(query: historyQuery, searchText: searchText)
    }

    package func searchHistory(_ query: String) {
        guard !closed, query != historyQuery else { return }
        historyQuery = query
        refreshHistory()
    }

    /// Reports the version shown for `record`. Only records retaining both
    /// transcripts can switch; original-only records report the original.
    func showTranscriptVariant(_ variant: DesktopTranscriptVariant, for record: DesktopRecordingStore.Record) {
        transcriptVariant = variant
        if record.hasTranscriptVariants {
            Platform.transcriptVariant(variant, for: record.id, switchable: true)
        } else {
            Platform.transcriptVariant(record.result == nil ? nil : .original, for: record.id, switchable: false)
        }
    }

    package func selectTranscriptVariant(_ variant: DesktopTranscriptVariant, identifier: String) {
        guard canUseHistory, let id = UUID(uuidString: identifier), id == selectedHistoryID,
              let record = history[id], record.hasTranscriptVariants else { return }
        transcriptVariant = variant
        transcript = record.text(for: variant) ?? ""
        let status = variant == .original
            ? "Showing the original transcript. Copy and Export use the version shown here."
            : "Showing the processed transcript. Copy and Export use the version shown here."
        Platform.historyPresentation(record, variant: variant, status: status)
    }

    package func retryHistory(_ identifier: String) async {
        guard canUseHistory, let id = UUID(uuidString: identifier),
              let record = history[id] else { return }
        guard DesktopTranscription.provider(for: record.modelIdentifier) != nil else {
            update("This used a live model. Open its audio, then choose Batch and import it to transcribe again.")
            return
        }
        busy = true
        activeOperations += 1
        defer { busy = false; finishOperation() }
        selectedHistoryID = id
        // A retry has no recording hotkey, so it never outputs automatically.
        await transcribe(record, duration: record.result?.duration ?? 0, output: nil)
    }

    /// Text and version were captured on the UI thread before the save dialog.
    /// A retry replacing the same record cannot change this action's content.
    package func exportHistory(text: String, variant: DesktopTranscriptVariant, path: String) async {
        guard !closed else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            try await store.exportTranscriptSnapshot(text, to: URL(fileURLWithPath: path))
            update(variant == .original
                ? "Original transcript exported." : "Transcript exported.")
        } catch { update("Could not export transcript: \(error.localizedDescription)") }
    }

    package func openHistoryAudio(_ identifier: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            let audio = try await store.audioURL(for: record)
            guard !closed else { return }
            try Platform.openFile(audio)
        } catch { update("Could not open recording: \(error.localizedDescription)") }
    }

}
