import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// The path and text were captured together before opening the native save
    /// dialog. Export never plays or changes a recording or its transcript.
    package func exportVoiceSource(
        _ snapshot: VoiceOutputSourceSnapshot, path: String, retainedAudio: Data? = nil,
        synthesize: @escaping @Sendable (
            VoiceOutputSourceSnapshot, DeepgramSpeechCatalog.Voice, @Sendable () async throws -> String
        ) async throws -> Data = { snapshot, voice, credential in
            try await DeepgramSpeechExport().synthesize(snapshot, voice: voice, credential: credential)
        }
    ) {
        guard !closed, canUseHistory else { return }
        let destination: URL
        do {
            destination = try voiceExportDestination(path)
        } catch { update(error.localizedDescription); return }
        stopReadAloud()
        playback.stop(announcing: false)
        let ticket = playbackRequests.begin()
        let voice = voiceOutputSettings().voice
        let effects = effects
        update(retainedAudio == nil ? "Synthesizing WAV with \(voice.name). Stop cancels export…" :
            "Exporting retained voice audio. No synthesis request is sent. Stop cancels export…")
        voiceOutputRecordID = snapshot.recordID
        activeOperations += 1
        readAloudState.exportTask = Task {
            defer { self.finishOperation() }
            do {
                let wav: Data
                if let retainedAudio { wav = retainedAudio } else {
                    wav = try await synthesize(snapshot, voice) {
                        try effects.apiKey(name: VoiceOutputProvider.deepgram.apiKeyIdentifier)
                    }
                }

                try Task.checkCancellation()
                guard !self.closed, self.playbackRequests.isCurrent(ticket) else { return }
                // No partial destination is ever published. A failed synthesis or
                // cancellation before this commit leaves any existing file intact.
                try await DesktopVoicePlaybackFile.writeExport(wav, to: destination)
                self.finishVoiceExport(ticket, status: retainedAudio == nil ? "Voice audio exported as WAV." :
                    "Retained voice audio exported as WAV; no synthesis request was sent.")
            } catch is CancellationError {
                self.finishVoiceExport(ticket, status: "Voice export cancelled.")
            } catch {
                self.finishVoiceExport(ticket, status: "Voice export failed: \(error.localizedDescription)")
            }
        }
    }

    package func voiceExportDestination(_ path: String) throws -> URL {
        let destination = URL(fileURLWithPath: path)
        guard !path.isEmpty, !path.utf8.contains(0), destination.pathExtension.lowercased() == "wav" else {
            throw DesktopHostError(message: "Choose a WAV file for voice export.")
        }
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
            throw DesktopHostError(message: "Choose an export location outside the app's data folder.")
        }
        return destination
    }

    private func finishVoiceExport(_ ticket: DesktopPlaybackRequests.Ticket, status: String) {
        guard !closed, playbackRequests.isCurrent(ticket) else { return }
        readAloudState.exportTask = nil
        voiceOutputRecordID = nil
        guard !busy, recording == nil else { return }
        update(status)
    }
}
