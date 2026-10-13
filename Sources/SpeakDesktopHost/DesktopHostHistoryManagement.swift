import Foundation
import SpeakDesktop

private struct HistoryDeletionOutcome {
    var removed = 0
    var failures = 0
    var firstFailure: String?
}

extension DesktopHostController {
    /// Native event queues drain before shutdown, so they admit work without
    /// waiting for a cloud request to finish.
    package func beginHistoryDeletion(_ identifiers: String, deleteAudio: Bool) {
        guard let candidates = admitHistoryDeletion(identifiers) else { return }
        historyDeletionTask = Task {
            await completeHistoryDeletion(candidates, deleteAudio: deleteAudio)
        }
    }

    /// IDs were frozen before the native confirmation. New arrivals, including
    /// rows outside a filtered view, must never expand that confirmed snapshot.
    package func deleteHistory(_ identifiers: String, deleteAudio: Bool) async {
        guard let candidates = admitHistoryDeletion(identifiers) else { return }
        await completeHistoryDeletion(candidates, deleteAudio: deleteAudio)
    }

    private func admitHistoryDeletion(_ identifiers: String) -> [UUID]? {
        guard canUseHistory else {
            update("History deletion is unavailable while another operation is running.")
            return nil
        }
        let names = identifiers.split(separator: "\n", omittingEmptySubsequences: false)
        let parsed = names.compactMap { UUID(uuidString: String($0)) }
        let requested = Set(parsed)
        guard !requested.isEmpty, parsed.count == names.count, requested.count == parsed.count else {
            update("Could not delete History: the confirmed recording identifiers are invalid.")
            return nil
        }
        let candidates = requested.filter { history[$0] != nil }.sorted { $0.uuidString < $1.uuidString }
        guard !candidates.isEmpty else {
            update("The confirmed History entries were already removed.")
            return nil
        }
        busy = true
        historyDeletionInProgress = true
        cancellationRequested = false
        activeOperations += 1
        update("Deleting confirmed History entries…", state: 2)
        if let outputID = outputSlot.recordID, requested.contains(outputID) { cancelOutput() }
        if let selected = selectedHistoryID, requested.contains(selected) {
            playback.stop(announcing: false)
            stopReadAloud()
        }
        return candidates
    }

    private func completeHistoryDeletion(_ candidates: [UUID], deleteAudio: Bool) async {
        defer {
            busy = false
            historyDeletionInProgress = false
            historyDeletionTask = nil
            finishOperation()
        }
        let outcome = await performHistoryDeletions(candidates, deleteAudio: deleteAudio)
        guard !closed else { return }
        if outcome.removed > 0 { cloudSync.historyChanged?() }
        refreshHistory()
        var status = "Removed \(outcome.removed) recording(s) from History."
        if !deleteAudio { status += " Saved audio files were kept." }
        if let firstFailure = outcome.firstFailure {
            status += " \(outcome.failures) deletion(s) need attention: \(firstFailure)"
        } else if Task.isCancelled || cancellationRequested {
            status += " Deletion stopped; remaining recordings were kept."
        }
        showSelectedHistory(status: status, state: 0)
    }

    private func performHistoryDeletions(_ candidates: [UUID], deleteAudio: Bool) async -> HistoryDeletionOutcome {
        var outcome = HistoryDeletionOutcome()
        for id in candidates {
            guard !closed, !Task.isCancelled, !cancellationRequested else { break }
            do {
                if let delete = cloudSync.deleteHistory {
                    try await delete(id, deleteAudio)
                } else {
                    try await store.delete(id: id, deleteAudio: deleteAudio)
                }
            } catch {
                outcome.failures += 1
                if outcome.firstFailure == nil { outcome.firstFailure = error.localizedDescription }
            }
            if await store.isDeleted(id: id) {
                discardDeletedHistory(id)
                outcome.removed += 1
            }
        }
        return outcome
    }

    private func discardDeletedHistory(_ id: UUID) {
        history[id] = nil
        historySearchText[id] = nil
        guard selectedHistoryID == id else { return }
        selectedHistoryID = nil
        transcript = ""
        transcriptVariant = .processed
        if !closed { Platform.transcriptVariant(nil, for: nil, switchable: false) }
    }
}
