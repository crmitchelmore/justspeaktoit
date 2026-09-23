import Foundation
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

extension WindowsNative {
    /// Record-bound playback display into the native latest-only mailbox. Safe
    /// from any thread; the window ignores reports for an unselected record.
    static func playback(_ display: WindowsAudioPlaybackDisplay) {
        let result = display.recordID.uuidString.withCString { record in
            display.text.withCString { jsti_window_set_playback(record, display.state.rawValue, $0) }
        }
        if result != 0 { update("The playback controls could not be refreshed.") }
    }
}

/// Native in-app playback of the selected History recording. This is additive:
/// Open audio still launches the registered external application. Play never
/// modifies the recording, uses only the store-resolved audio URL, and stops
/// before recording, importing, switching records or closing.
extension WindowsAppController {
    func preparePlayback() {
        playback.setPresenter(WindowsAudioPlaybackPresenter(
            show: { WindowsNative.playback($0) },
            status: { [weak self] message in Task { await self?.playbackStatus(message) } }
        ))
    }

    /// Terminal playback outcomes share the status line, but never while a
    /// recording or transcription owns it.
    func playbackStatus(_ status: WindowsAudioPlaybackStatus) {
        guard !closed, !busy, recording == nil, playback.isCurrent(revision: status.revision) else { return }
        update(status.message)
    }

    /// Play/Pause for the selected record: pauses or resumes an active run for
    /// that record, otherwise starts a new run from the canonical audio file.
    /// Whatever ends playback while the file is resolved (Stop, another row,
    /// recording, import, closing) ends this request, so it never starts
    /// audio after them, even when the row is still selected.
    func playbackToggle(_ identifier: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        if playback.togglePause(recordID: id) { return }
        guard canUseHistory, selectedHistoryID == id, isVisible(id), !refuseSyncedAudio(record) else { return }
        // History playback replaces Read aloud, including a segment still being synthesized.
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
    func playbackStop() {
        guard !closed else { return }
        let reading = readAloudState.task != nil
        stopReadAloud()
        playback.stop(announcing: true)
        guard reading, !busy, recording == nil else { return }
        update("Reading aloud stopped.")
    }
}
