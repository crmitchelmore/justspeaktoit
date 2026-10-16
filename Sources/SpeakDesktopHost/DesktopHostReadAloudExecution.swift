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
    // swiftlint:disable:next function_body_length
    func startVoiceRead(text: String, source: VoiceOutputSource, owner: UUID, recordID: UUID?) {
        // One cohesive playback-lifecycle body: voice selection, optional
        // Deepgram output staging, speech start, and the read-aloud Task all
        // share local state (`speech`, `voiceOutput`, `ticket`) that would
        // otherwise need threading through several extracted helpers.
        let selection: DesktopSpeechSelection
        do {
            selection = try currentVoiceSelection()
        } catch {
            update("Read aloud failed: \(error.localizedDescription)"); return
        }
        let staging = directory.appendingPathComponent("VoiceOutput")
        let voiceOutput: Platform.VoiceOutput?
        if case .deepgram = selection.voice, selection.sampleRate == VoiceSynthesisQuality.high.sampleRate {
            guard let output = readAloudState.output({ try Platform.makeVoiceOutput(stagingDirectory: staging) }) else {
                update("Read aloud is unavailable: its private audio folder could not be prepared.")
                return
            }
            voiceOutput = output
        } else {
            voiceOutput = nil
        }
        stopReadAloud()
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
        let accountWork = beginAccountVoiceWork(selection, ticket: ticket)
        activeOperations += 1
        readAloudState.task = Task {
            defer { self.finishAccountVoiceOperation(accountWork, usage: usage) }
            var outcome: String?
            do {
                try await VoiceSynthesisUsage.$capture.withValue(usage?.capture) {
                    let original = try VoiceOutputSourceSnapshot(source: source, text: text, recordID: recordID)
                    let prepared = try await self.prepareVoiceSynthesisSource(
                        original, selection: selection, ticket: ticket)
                    if let recordID {
                        guard self.canUseHistory, self.selectedHistoryID == recordID,
                              self.isVisible(recordID) else { throw CancellationError() }
                    }
                    try await self.executeVoiceRead(
                        source: prepared, selection: selection, output: voiceOutput, speech: speech
                    )
                }
                outcome = "Finished reading aloud."
            } catch {
                outcome = self.readAloudFailureStatus(error)
            }
            self.finishReadAloud(ticket, status: outcome)
        }
    }

    private func readAloudFailureStatus(_ error: Error) -> String {
        switch error {
        case is CancellationError:
            return "Reading aloud stopped."
        case DeepgramSpeechError.missingCredential:
            return "Save a Deepgram API key (\(Platform.deepgramKeyHint)) to read aloud."
        default:
            return "Read aloud failed: \(error.localizedDescription)"
        }
    }

    func executeVoiceRead(
        source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        output: Platform.VoiceOutput?, speech: Platform.Playback.Speech
    ) async throws {
        let effects = effects
        let playback = playback
        if case .deepgram(let voice) = selection.voice, let output {
            for segment in SpeechTextSegmenter.segments(source.text) {
                try Task.checkCancellation()
                let request = try DeepgramSpeechRequest(text: segment, voice: voice, speed: selection.options.speed)
                _ = try await output.speak(request, credential: {
                    try await Self.readVoiceSynthesisKey(effects: effects, name: selection.voice.apiKeyIdentifier)
                }, through: { file in
                    try await playback.playToCompletion(speech, path: file.path)
                })
            }
        } else {
            let wav = try await Platform.synthesizeVoiceOutput(source, selection: selection) {
                try await Self.readVoiceSynthesisKey(effects: effects, name: selection.voice.apiKeyIdentifier)
            }
            try await DesktopVoicePlaybackFile.play(
                VoiceGeneratedAudio(validating: wav, sampleRate: selection.sampleRate),
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
