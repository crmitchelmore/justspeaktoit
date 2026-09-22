import Foundation
import CWindowsSupport
import SpeakDesktop

extension WindowsAppController {
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

    func refreshHistory() {
        guard !closed else { return }
        let visible = visibleHistory()
        if let selected = selectedHistoryID, !visible.contains(where: { $0.id == selected }) {
            // The displayed record no longer matches the search. Drop the stale
            // text and action target rather than acting on a hidden record.
            selectedHistoryID = nil
            transcript = ""
            transcriptVariant = .processed
            WindowsNative.history(visible, selected: nil)
            WindowsNative.transcriptVariant(nil, for: nil, switchable: false)
            update(
                "The selected recording is hidden by this search. Clear the search or choose a matching recording.",
                transcript: ""
            )
            return
        }
        WindowsNative.history(visible, selected: selectedHistoryID)
    }

    func selectHistory(_ identifier: String) {
        guard canUseHistory, let id = UUID(uuidString: identifier),
              let record = history[id], isVisible(id) else { return }
        selectedHistoryID = id
        transcript = record.text(for: .processed) ?? ""
        let status = record.failure ?? record.postProcessingFailure.map { "Post-processing failed: \($0)" }
            ?? (record.hasTranscriptVariants
                ? "Saved transcript. Transcript version switches between the processed and original text."
                : "Saved transcript. Retry uses this recording’s original model.")
        update(status + profileContext(record), transcript: transcript)
        showTranscriptVariant(.processed, for: record)
    }

    /// A selection event for a record that a newer search has already hidden
    /// is stale; honouring it would display text for a row that is not shown.
    func isVisible(_ id: UUID) -> Bool {
        guard let record = history[id] else { return false }
        let searchText = historySearchText[id] ?? DesktopHistorySearch.searchText(for: record)
        return DesktopHistorySearch.matches(query: historyQuery, searchText: searchText)
    }

    func searchHistory(_ query: String) {
        guard !closed, query != historyQuery else { return }
        historyQuery = query
        refreshHistory()
    }

    /// Reports the version shown for `record`. Only records retaining both
    /// transcripts can switch; original-only records report the original.
    func showTranscriptVariant(_ variant: DesktopTranscriptVariant, for record: DesktopRecordingStore.Record) {
        transcriptVariant = variant
        if record.hasTranscriptVariants {
            WindowsNative.transcriptVariant(variant, for: record.id, switchable: true)
        } else {
            WindowsNative.transcriptVariant(record.result == nil ? nil : .original, for: record.id, switchable: false)
        }
    }

    func selectTranscriptVariant(_ variant: DesktopTranscriptVariant, identifier: String) {
        guard canUseHistory, let id = UUID(uuidString: identifier), id == selectedHistoryID,
              let record = history[id], record.hasTranscriptVariants else { return }
        transcriptVariant = variant
        transcript = record.text(for: variant) ?? ""
        update(variant == .original
            ? "Showing the original transcript. Copy and Export use the version shown here."
            : "Showing the processed transcript. Copy and Export use the version shown here.", transcript: transcript)
    }

    func retryHistory(_ identifier: String) async {
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
        await transcribe(record, duration: record.result?.duration ?? 0, target: nil)
    }

    /// `variant` was captured with the record ID on the UI thread before the
    /// save dialog opened, so the export matches what the window displayed.
    func exportHistory(_ identifier: String, variant: DesktopTranscriptVariant = .processed, path: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            try await store.exportTranscript(id: id, variant: variant, to: URL(fileURLWithPath: path))
            update(variant == .original && record.hasTranscriptVariants
                ? "Original transcript exported." : "Transcript exported.")
        } catch { update("Could not export transcript: \(error.localizedDescription)") }
    }

    func openHistoryAudio(_ identifier: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        activeOperations += 1
        defer { finishOperation() }
        do {
            let audio = try await store.audioURL(for: record)
            guard !closed else { return }
            try audio.path.withCString { path in
                try WindowsNative.checked { jsti_shell_open_file(path, $0, $1) }
            }
        } catch { update("Could not open recording: \(error.localizedDescription)") }
    }

}
