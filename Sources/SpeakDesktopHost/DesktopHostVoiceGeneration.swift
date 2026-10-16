import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopGeneratedVoiceResult: Sendable {
    package let id = UUID()
    package let source: VoiceOutputSourceSnapshot
    package let voice: DesktopSpeechVoice
    package let options: VoiceSynthesisOptions
    package let audio: VoiceGeneratedAudio
}

package struct DesktopVoiceResultPresentation: Sendable {
    package let resultID: String
    package let working: Bool
    package let message: String
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func generateVoiceSource(
        _ snapshot: VoiceOutputSourceSnapshot, options: VoiceGenerationOptions,
        synthesize: @escaping @Sendable (
            VoiceOutputSourceSnapshot, DesktopSpeechSelection, @Sendable () async throws -> String
        ) async throws -> Data = { snapshot, selection, credential in
            try await DesktopSpeechSynthesis().synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                accountInventory: selection.accountInventory, sonioxRegion: selection.sonioxRegion,
                language: selection.language, credential: credential
            )
        }
    ) {
        guard !closed else { return }
        guard canUseHistory else {
            presentVoiceResult(working: false, message:
                "Finish the current recording or operation before generating audio.")
            return
        }
        guard voiceGenerationTask == nil else {
            presentVoiceResult(working: false, message:
                "The previous generated-audio operation is still closing. Try Generate again when it finishes.")
            return
        }
        let selection: DesktopSpeechSelection
        do { selection = try currentVoiceSelection() } catch {
            presentVoiceResult(working: false, message: error.localizedDescription); return
        }
        stopReadAloud()
        playback.stop(announcing: false)
        let ticket = playbackRequests.begin()
        let voice = selection.voice
        voiceOutputRecordID = snapshot.recordID
        presentVoiceResult(working: true, message: "Generating voice audio with \(voice.name)…")
        let usage = beginVoiceUsage(operation: .generate, source: snapshot.source, recordID: snapshot.recordID)
        let accountWork = beginAccountVoiceWork(selection, ticket: ticket)
        activeOperations += 1
        voiceGenerationTask = Task {
            defer {
                self.finishAccountVoiceWork(accountWork)
                self.finishVoiceUsage(usage)
                self.voiceGenerationTask = nil
                self.finishOperation()
                self.settleVoiceAccountPresentation()
            }
            await VoiceSynthesisUsage.$capture.withValue(usage?.capture) {
                await self.runVoiceGeneration(
                    snapshot, selection: selection, options: options, ticket: ticket, synthesize: synthesize
                )
            }
        }
    }

    private func runVoiceGeneration(
        _ snapshot: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        options: VoiceGenerationOptions, ticket: DesktopPlaybackRequests.Ticket,
        synthesize: @Sendable (
            VoiceOutputSourceSnapshot, DesktopSpeechSelection, @Sendable () async throws -> String
        ) async throws -> Data
    ) async {
        let effects = effects
        var saveWarning: String?
        var published = false
        do {
            let wav = try await synthesize(snapshot, selection) {
                try await Self.readVoiceSynthesisKey(effects: effects, name: selection.voice.apiKeyIdentifier)
            }
            try Task.checkCancellation()
            guard voiceTicketIsCurrent(ticket) else { return }
            let result = try DesktopGeneratedVoiceResult(
                source: snapshot, voice: selection.voice, options: selection.options,
                audio: VoiceGeneratedAudio(validating: wav, sampleRate: selection.sampleRate)
            )
            saveWarning = try await archiveGeneratedAudio(result.audio, enabled: options.saveToRecordings)
            try Task.checkCancellation()
            guard voiceTicketIsCurrent(ticket) else { return }
            generatedVoice = result
            published = true
            if options.autoPlay {
                try await playVoiceResult(result, ticket: ticket)
                try Task.checkCancellation()
            }
            finishGeneratedVoice(ticket, message: saveWarning ?? (options.autoPlay
                ? "Generated voice audio finished playing. Play or export the retained result."
                : "Voice audio generated without playback. Play or export the retained result."))
        } catch is CancellationError {
            finishGeneratedVoice(ticket, message: "Voice generation stopped. The previous result is retained.")
        } catch {
            let failure = published ? "Generated audio could not be played: " : "Voice generation failed: "
            finishGeneratedVoice(ticket, message: failure + error.localizedDescription
                + (saveWarning.map { " " + $0 } ?? ""))
        }
    }

    private func archiveGeneratedAudio(_ audio: VoiceGeneratedAudio, enabled: Bool) async throws -> String? {
        guard enabled else { return nil }
        do {
            _ = try await store.archiveVoiceAudio(audio)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch let committed as VoiceArchiveCommittedCleanupFailure {
            return committed.localizedDescription
        } catch {
            return "Generated audio could not be saved to recordings: \(error.localizedDescription)"
        }
    }

    package func playGeneratedVoice(_ resultID: String) {
        guard !closed, canUseHistory, let result = generatedVoice, result.id.uuidString == resultID else {
            if !closed {
                presentVoiceResult(working: voiceGenerationTask != nil,
                                   message: "That generated result is no longer available. Generate audio again.")
            }
            return
        }
        guard voiceGenerationTask == nil else {
            presentVoiceResult(working: false, message:
                "The previous generated-audio operation is still closing. Try Play again when it finishes.")
            return
        }
        stopReadAloud()
        playback.stop(announcing: false)
        let ticket = playbackRequests.begin()
        voiceOutputRecordID = result.source.recordID
        presentVoiceResult(working: true, message: "Playing retained voice audio; no synthesis request is sent.")
        activeOperations += 1
        voiceGenerationTask = Task {
            defer { self.voiceGenerationTask = nil; self.finishOperation() }
            do {
                try await self.playVoiceResult(result, ticket: ticket)
                self.finishGeneratedVoice(ticket, message: "Generated voice audio finished playing.")
            } catch is CancellationError {
                self.finishGeneratedVoice(ticket, message: "Generated audio playback stopped.")
            } catch {
                self.finishGeneratedVoice(ticket, message:
                    "Generated audio playback failed: \(error.localizedDescription)")
            }
        }
    }

    package func exportGeneratedVoice(_ resultID: String, path: String) {
        guard !closed, canUseHistory, let result = generatedVoice, result.id.uuidString == resultID else {
            if !closed {
                presentVoiceResult(working: voiceGenerationTask != nil,
                                   message: "That generated result is no longer available. Generate audio again.")
            }
            return
        }
        exportVoiceSource(result.source, path: path, retainedAudio: result.audio.wav)
    }

    package func discardGeneratedVoice(for recordID: UUID) {
        if voiceOutputRecordID == recordID {
            stopReadAloud()
            playback.stop(announcing: false)
        }
        guard generatedVoice?.source.recordID == recordID else { return }
        generatedVoice = nil
        Platform.voiceGenerated(.init(resultID: "", working: voiceGenerationTask != nil,
                                      message: "The History-owned result was removed."))
    }

    private func voiceTicketIsCurrent(_ ticket: DesktopPlaybackRequests.Ticket) -> Bool {
        !closed && playbackRequests.isCurrent(ticket)
    }

    private func presentVoiceResult(working: Bool, message: String) {
        update(message)
        Platform.voiceGenerated(.init(
            resultID: generatedVoice?.id.uuidString ?? "", working: working, message: message
        ))
    }

    private func finishGeneratedVoice(_ ticket: DesktopPlaybackRequests.Ticket, message: String) {
        guard voiceTicketIsCurrent(ticket) else { return }
        if let speech = readAloudState.speech { playback.endSpeech(speech) }
        readAloudState.speech = nil
        voiceOutputRecordID = nil
        guard !busy, recording == nil else { return }
        presentVoiceResult(working: false, message: message)
    }

    private func playVoiceResult(
        _ result: DesktopGeneratedVoiceResult, ticket: DesktopPlaybackRequests.Ticket
    ) async throws {
        try Task.checkCancellation()
        guard voiceTicketIsCurrent(ticket) else { throw CancellationError() }
        let speech = try playback.beginSpeech(recordID: result.source.recordID ?? UUID())
        readAloudState.speech = speech
        let playback = playback
        try await DesktopVoicePlaybackFile.play(
            result.audio, directory: directory.appendingPathComponent("VoiceGeneratedPlayback"),
            prepare: { try Platform.preparePrivateDirectory($0) },
            through: { try await playback.playToCompletion(speech, path: $0.path) }
        )
    }
}
