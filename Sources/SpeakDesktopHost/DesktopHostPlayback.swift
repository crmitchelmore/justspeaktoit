import Foundation
import SpeakDesktop

/// Native in-app playback of the selected History recording. This is additive:
/// Open audio still launches the registered external application. Play never
/// modifies the recording, uses only the store-resolved audio URL, and stops
/// before recording, importing, switching records or closing.
extension DesktopHostController {
    func preparePlayback() {
        playback.setStatusHandler { [weak self] revision, message in
            Task { await self?.playbackStatus(revision: revision, message: message) }
        }
    }

    /// Terminal playback outcomes share the status line, but never while a
    /// recording or transcription owns it.
    func playbackStatus(revision: UInt64, message: String) {
        guard !closed, !busy, recording == nil, playback.isCurrent(revision: revision) else { return }
        update(message)
    }

    /// Play/Pause for the selected record: pauses or resumes its active run,
    /// or its Read aloud while a segment is synthesised, otherwise starts a
    /// new run from the canonical audio file. Whatever ends playback while
    /// the file is resolved (Stop, another row, recording, import, closing)
    /// ends this request, so it never starts audio after them, even when the
    /// row is still selected.
    package func playbackToggle(_ identifier: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        if playback.togglePause(recordID: id) { return }
        guard canUseHistory, selectedHistoryID == id, isVisible(id), !refuseSyncedAudio(record) else { return }
        // A new History playback supersedes every earlier request, Read aloud included.
        stopReadAloud()
        let ticket = playbackRequests.begin()
        activeOperations += 1
        defer { finishOperation() }
        do {
            let audio = try await store.audioURL(for: record)
            // Re-check after the suspension: the selection, a recording or
            // shutdown may have changed while the store resolved the file.
            guard playbackRequests.isCurrent(ticket), !closed, canUseHistory, selectedHistoryID == id else { return }
            try playback.play(recordID: id, path: audio.path, knownDuration: record.result?.duration)
        } catch {
            guard playbackRequests.isCurrent(ticket), !busy, recording == nil else { return }
            update("Could not play recording: \(error.localizedDescription)")
        }
    }

    /// The user's Stop: ends History playback and Read aloud, including a
    /// start still resolving its audio and a segment still being synthesized.
    /// Only this stop reports "Playback stopped."; the ended Read aloud can no
    /// longer report, so its stop is reported here.
    package func playbackStop() {
        guard !closed else { return }
        let reading = Platform.isReadingAloud(readAloudState)
        stopReadAloud()
        playback.stop(announcing: true)
        guard reading, !busy, recording == nil else { return }
        update("Reading aloud stopped.")
    }
}
