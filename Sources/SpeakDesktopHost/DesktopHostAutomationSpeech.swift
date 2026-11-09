import Foundation
import SpeakCore
import SpeakDesktop

/// `speak say` on Windows and Linux: the Voice settings' providers, saved keys,
/// pronunciation and usage ledger, through the same playback and export paths
/// the Voice window uses. One speech runs at a time; Stop in the window, a new
/// recording or shutdown cancels it.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func automationSpeak(_ speech: AutomationSpeechRequest) async throws -> AutomationResult {
        try checkAutomationSpeechAdmission()
        let prepared = try await prepareAutomationSpeech(speech)
        // The format check can suspend; a recording or shutdown may have begun.
        do { try checkAutomationSpeechAdmission() } catch {
            finishVoiceAudioConversion(prepared.conversionID)
            throw error
        }
        let (selection, snapshot, destination) = (prepared.selection, prepared.snapshot, prepared.destination)
        let conversionID = prepared.conversionID
        stopReadAloud()
        playback.stop(announcing: false)
        let ticket = playbackRequests.begin()
        let usage = beginVoiceUsage(operation: .generate, source: .typedText, recordID: nil)
        let accountWork = beginAccountVoiceWork(selection, ticket: ticket)
        activeOperations += 1
        // Owned like Export, so Stop, a recording and closing cancel it; the
        // socket request only awaits it.
        let work = Task { () throws in
            let canonical = try await VoiceSynthesisUsage.$capture.withValue(usage?.capture) {
                try await self.synthesizeAutomationSpeech(snapshot, selection: selection, ticket: ticket)
            }
            if let output = speech.output, let destination {
                let audio = try await Platform.encodeVoiceAudio(canonical, format: output.format)
                guard audio.format == output.format else { throw VoiceAudioFormatError.invalidContainer }
                try self.checkAutomationSpeech(ticket)
                try await DesktopVoicePlaybackFile.writeExport(audio.data, to: destination)
            }
            if speech.play { try await self.playAutomationSpeech(canonical, ticket: ticket) }
        }
        let owner = Task { await withTaskCancellationHandler { _ = await work.result } onCancel: { work.cancel() } }
        readAloudState.exportTask = owner
        defer {
            if readAloudState.exportTask == owner { readAloudState.exportTask = nil }
            finishVoiceAudioConversion(conversionID)
            endAutomationSpeech(ticket)
            finishAccountVoiceOperation(accountWork, usage: usage)
        }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            throw Self.automationSpeechError(error)
        }
        var result = AutomationResult()
        result.voice = selection.voice.id
        result.path = speech.output?.path
        return result
    }

    private func checkAutomationSpeechAdmission() throws {
        guard isReady, !closed else {
            throw AutomationError(code: .appUnavailable, message: "Just Speak to It is not ready or is closing.")
        }
        guard canUseHistory, voiceGenerationTask == nil else {
            throw AutomationError(
                code: .alreadyRecording,
                message: "Finish the current recording or voice operation before speaking text."
            )
        }
    }

    private struct PreparedAutomationSpeech {
        let selection: DesktopSpeechSelection
        let snapshot: VoiceOutputSourceSnapshot
        let destination: URL?
        let conversionID: UUID?
    }

    /// Everything that can be refused is checked before any credit is spent.
    private func prepareAutomationSpeech(_ speech: AutomationSpeechRequest) async throws -> PreparedAutomationSpeech {
        do {
            let selection = try automationSpeechSelection(speech.voice)
            let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: speech.text)
            let destination = try speech.output.map { try voiceExportDestination($0.path) }
            if let output = speech.output {
                try await Platform.requireVoiceAudioFormat(output.format, sampleRate: selection.sampleRate)
            }
            let conversionID = try speech.output.flatMap { try admitVoiceAudioConversion($0.format) }
            return .init(selection: selection, snapshot: snapshot, destination: destination, conversionID: conversionID)
        } catch let error as AutomationError {
            throw error
        } catch {
            throw AutomationError(code: .invalidArgument, message: error.localizedDescription)
        }
    }

    private static func automationSpeechError(_ error: Error) -> AutomationError {
        switch error {
        case let error as AutomationError: error
        case is CancellationError:
            AutomationError(code: .speechFailed, message: "Speech was stopped before it finished.")
        default: AutomationError(code: .speechFailed, message: error.localizedDescription)
        }
    }

    /// No desktop host has an on-device voice yet, so the default fails clearly
    /// rather than spending a cloud provider's credit unasked.
    func automationSpeechSelection(_ voice: AutomationSpeechVoice) throws -> DesktopSpeechSelection {
        switch voice {
        case .onDevice:
            throw AutomationError.noOnDeviceVoice(platform: Platform.displayName)
        case .app:
            return try currentVoiceSelection()
        case .identifier(let identifier):
            var settings = voiceOutputSettings()
            settings.modelID = nil
            settings.voiceID = identifier
            settings.strictVoiceSelection = true
            let inventory = identifier.hasPrefix(MistralTTSCatalog.voiceIDPrefix)
                ? voiceDiscovery.inventories[.mistral] : selectedVoiceAccountInventory
            do {
                return try settings.synthesisSelection(accountInventory: inventory)
            } catch {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "Voice \"\(identifier)\" is not available: \(error.localizedDescription)"
                )
            }
        }
    }

    private func synthesizeAutomationSpeech(
        _ snapshot: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        ticket: DesktopPlaybackRequests.Ticket
    ) async throws -> VoiceGeneratedAudio {
        let effects = effects
        let prepared = try await prepareVoiceSynthesisSource(snapshot, selection: selection, ticket: ticket)
        let wav = try await Platform.synthesizeVoiceOutput(prepared, selection: selection) {
            try await Self.readVoiceSynthesisKey(effects: effects, name: selection.voice.apiKeyIdentifier)
        }
        try checkAutomationSpeech(ticket)
        return try VoiceGeneratedAudio(validating: wav, sampleRate: selection.sampleRate)
    }

    private func playAutomationSpeech(
        _ audio: VoiceGeneratedAudio, ticket: DesktopPlaybackRequests.Ticket
    ) async throws {
        try checkAutomationSpeech(ticket)
        let speech = try playback.beginSpeech(recordID: UUID())
        readAloudState.speech = speech
        let playback = playback
        try await DesktopVoicePlaybackFile.play(
            audio, directory: directory.appendingPathComponent("VoiceGeneratedPlayback"),
            prepare: { try Platform.preparePrivateDirectory($0) },
            through: { try await playback.playToCompletion(speech, path: $0.path) }
        )
    }

    private func checkAutomationSpeech(_ ticket: DesktopPlaybackRequests.Ticket) throws {
        try Task.checkCancellation()
        guard !closed, playbackRequests.isCurrent(ticket) else { throw CancellationError() }
    }

    private func endAutomationSpeech(_ ticket: DesktopPlaybackRequests.Ticket) {
        guard !closed, playbackRequests.isCurrent(ticket) else { return }
        if let speech = readAloudState.speech { playback.endSpeech(speech) }
        readAloudState.speech = nil
    }
}
