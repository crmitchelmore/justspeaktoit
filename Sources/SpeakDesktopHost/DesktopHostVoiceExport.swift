import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// The path and text were captured together before opening the native save
    /// dialog. Export never plays or changes a recording or its transcript.
    package func exportVoiceSource(
        _ snapshot: VoiceOutputSourceSnapshot, path: String,
        synthesize: @escaping @Sendable (
            VoiceOutputSourceSnapshot, DeepgramSpeechCatalog.Voice, @Sendable () async throws -> String
        ) async throws -> Data = { snapshot, voice, credential in
            try await DeepgramSpeechExport().synthesize(snapshot, voice: voice, credential: credential)
        }
    ) {
        guard !closed, canUseHistory else { return }
        let destination = URL(fileURLWithPath: path)
        guard !path.isEmpty, !path.utf8.contains(0), destination.pathExtension.lowercased() == "wav" else {
            update("Choose a WAV file for voice export.")
            return
        }
        // Never allow an export to replace the app's durable records or settings.
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        #if os(Windows)
        let candidate = resolved.lowercased()
        let protectedRoot = root.lowercased()
        #else
        let candidate = resolved
        let protectedRoot = root
        #endif
        guard candidate != protectedRoot, !candidate.hasPrefix(protectedRoot + "/"),
              !candidate.hasPrefix(protectedRoot + "\\") else {
            update("Choose an export location outside the app's data folder.")
            return
        }
        stopReadAloud()
        playback.stop(announcing: false)
        let ticket = playbackRequests.begin()
        let voice = voiceOutputSettings().voice
        let effects = effects
        update("Synthesizing WAV with \(voice.name). Stop cancels export…")
        voiceOutputRecordID = snapshot.recordID
        activeOperations += 1
        readAloudState.exportTask = Task {
            defer { self.finishOperation() }
            do {
                let wav = try await synthesize(snapshot, voice) {
                    try effects.apiKey(name: VoiceOutputProvider.deepgram.apiKeyIdentifier)
                }
                try Task.checkCancellation()
                guard !self.closed, self.playbackRequests.isCurrent(ticket) else { return }
                // No partial destination is ever published. A failed synthesis or
                // cancellation before this commit leaves any existing file intact.
                try wav.write(to: destination, options: .atomic)
                self.finishVoiceExport(ticket, status: "Voice audio exported as WAV.")
            } catch is CancellationError {
                self.finishVoiceExport(ticket, status: "Voice export cancelled.")
            } catch {
                self.finishVoiceExport(ticket, status: "Voice export failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishVoiceExport(_ ticket: DesktopPlaybackRequests.Ticket, status: String) {
        guard !closed, playbackRequests.isCurrent(ticket) else { return }
        readAloudState.exportTask = nil
        voiceOutputRecordID = nil
        guard !busy, recording == nil else { return }
        update(status)
    }
}
