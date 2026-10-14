import Foundation
import SpeakCore
import SpeakDesktop

/// Read aloud's segment-by-segment synthesis and playback, split out of
/// `DesktopHostReadAloud.swift` to keep that file under the file-length
/// threshold. These remain implementation details of the same
/// `DesktopHostController` extension — not part of its package-visible API —
/// so they are module-internal rather than `private` only because Swift's
/// `private` is scoped to a single file and cannot span this split.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    func startVoiceRead(text: String, source: VoiceOutputSource, owner: UUID, recordID: UUID?) {
        let selection: DesktopSpeechSelection
        do {
            selection = try currentVoiceSelection()
        } catch {
            update("Read aloud failed: \(error.localizedDescription)"); return
        }
        let staging = directory.appendingPathComponent("VoiceOutput")
        let voiceOutput: Platform.VoiceOutput?
        if case .deepgram = selection.voice {
            guard let output = readAloudState.output({ try Platform.makeVoiceOutput(stagingDirectory: staging) }) else {
                update("Read aloud is unavailable: its private audio folder could not be prepared.")
                return
            }
            voiceOutput = output
        } else {
            voiceOutput = nil
        }
        let speech: Platform.Playback.Speech
        do {
            // Playback stops now, and the record's controls stay active until the speech ends.
            speech = try playback.beginSpeech(recordID: owner)
        } catch {
            update("Read aloud failed: \(error.localizedDescription)")
            return
        }
        let voice = selection.voice
        let ticket = playbackRequests.begin()
        readAloudState.speech = speech
        voiceOutputRecordID = recordID
        update("Reading aloud with \(voice.name)…")
        let usage = beginVoiceUsage(operation: .read, source: source, recordID: recordID)
        activeOperations += 1
        readAloudState.task = Task {
            defer { self.finishVoiceUsage(usage); self.finishOperation() }
            var outcome: String?
            do {
                try await VoiceSynthesisUsage.$capture.withValue(usage?.capture) {
                    try await self.executeVoiceRead(
                        text: text, recordID: recordID, selection: selection, output: voiceOutput, speech: speech
                    )
                }
                outcome = "Finished reading aloud."
            } catch is CancellationError {
                outcome = "Reading aloud stopped."
            } catch DeepgramSpeechError.missingCredential {
                outcome = "Save a Deepgram API key (\(Platform.deepgramKeyHint)) to read aloud."
            } catch {
                outcome = "Read aloud failed: \(error.localizedDescription)"
            }
            self.finishReadAloud(ticket, status: outcome)
        }
    }

    func executeVoiceRead(
        text: String, recordID: UUID?, selection: DesktopSpeechSelection,
        output: Platform.VoiceOutput?, speech: Platform.Playback.Speech
    ) async throws {
        let effects = effects
        let playback = playback
        if case .deepgram(let voice) = selection.voice, let output {
            for segment in SpeechTextSegmenter.segments(text) {
                try Task.checkCancellation()
                let request = try DeepgramSpeechRequest(text: segment, voice: voice, speed: selection.options.speed)
                _ = try await output.speak(request, credential: {
                    try effects.apiKey(name: selection.voice.apiKeyIdentifier)
                }, through: { file in
                    try await playback.playToCompletion(speech, path: file.path)
                })
            }
        } else {
            let source = try VoiceOutputSourceSnapshot(
                source: recordID == nil ? .typedText : .history, text: text, recordID: recordID
            )
            let wav = try await Platform.synthesizeVoiceOutput(source, selection: selection) {
                try effects.apiKey(name: selection.voice.apiKeyIdentifier)
            }
            try await DesktopVoicePlaybackFile.play(
                VoiceGeneratedAudio(validating: wav),
                directory: directory.appendingPathComponent("VoiceGeneratedPlayback"),
                prepare: { try Platform.preparePrivateDirectory($0) },
                through: { try await playback.playToCompletion(speech, path: $0.path) }
            )
        }
    }

    func finishReadAloud(_ ticket: DesktopPlaybackRequests.Ticket, status: String?) {
        guard playbackRequests.isCurrent(ticket) else { return }
        // The finishing task is not cancelled; only its speech is ended.
        readAloudState.task = nil
        voiceOutputRecordID = nil
        Platform.stopReadAloud(&readAloudState, playback: playback)
        guard !closed, !busy, recording == nil, let status else { return }
        update(status)
    }
}
