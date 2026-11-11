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
        result.voice = selection.voice.favoriteIdentifier
        result.model = selection.voice.modelID
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
            let choice = try AutomationVoiceResolver.resolve(speech.voice, in: await automationVoices())
            let selection = try automationSpeechSelection(
                choice, overrides: speech.settings, modelRequested: speech.voice.model != nil)
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

    /// Every catalogue voice whose provider key is saved, one row per voice
    /// with its models, plus the selected voice. These hosts have no
    /// on-device voice, so the default needs a configured voice.
    package func automationVoices() async throws -> [AutomationVoice] {
        let effects = effects
        let catalogue = DesktopSpeechVoice.voices
        var keyed: [String: Bool] = [:]
        for name in Set(catalogue.map(\.apiKeyIdentifier)) {
            let key = try? await Self.readVoiceSynthesisKey(effects: effects, name: name)
            keyed[name] = key?.isEmpty == false
        }
        let selected = try? currentVoiceSelection().voice
        var rows: [AutomationVoice] = []
        var index: [String: Int] = [:]
        for voice in catalogue + [selected].compactMap({ $0 }) where keyed[voice.apiKeyIdentifier] != false {
            let id = voice.favoriteIdentifier
            if let position = index[id] {
                if !rows[position].models.contains(voice.modelID) { rows[position].models.append(voice.modelID) }
                continue
            }
            index[id] = rows.count
            let provider = voice.automationProvider
            rows.append(AutomationVoice(
                id: id, name: voice.name, provider: provider.id, providerName: provider.name,
                models: [voice.modelID], model: voice.modelID
            ))
        }
        if let selected, let position = index[selected.favoriteIdentifier] {
            rows[position].selected = true
            rows[position].model = selected.modelID
        }
        return rows
    }

    /// The synthesis settings for one resolved voice and this call's
    /// overrides. Unchanged, the selected voice keeps its exact saved
    /// configuration; anything else is resolved strictly, never substituted,
    /// and nothing is saved.
    func automationSpeechSelection(
        _ choice: AutomationVoiceChoice, overrides: AutomationSpeechSettings = .init(), modelRequested: Bool = false
    ) throws -> DesktopSpeechSelection {
        let unchanged = choice.voice.selected && choice.model == choice.voice.model
        if unchanged, overrides.isEmpty { return try currentVoiceSelection() }
        var settings = voiceOutputSettings()
        let inventory = choice.voice.id.hasPrefix(MistralTTSCatalog.voiceIDPrefix)
            ? voiceDiscovery.inventories[.mistral] : selectedVoiceAccountInventory
        let selection: DesktopSpeechSelection
        do {
            if !unchanged {
                let voice = try DesktopSpeechVoice.strictlyResolved(
                    modelID: choice.model, voiceID: choice.voice.id, accountInventory: inventory)
                settings.modelID = choice.model
                settings.voiceID = choice.voice.id
                settings.strictVoiceSelection = true
                switch voice {
                case .openai, .elevenlabs: settings.quality = voice.defaultQuality.rawValue
                default: break
                }
            }
            try overrides.validate(for: settings.storedVoice(accountInventory: inventory))
            if let speed = overrides.speed { settings.speed = speed }
            if let pitch = overrides.pitch { settings.pitch = pitch }
            if let language = overrides.language { settings.language = language }
            // An explicit model wins where quality would otherwise pick the model.
            if let quality = overrides.quality, !modelRequested { settings.quality = quality.rawValue }
            selection = try settings.synthesisSelection(accountInventory: inventory)
        } catch let error as AutomationError {
            throw error
        } catch {
            throw AutomationError(
                code: .invalidArgument,
                message: "Voice \"\(choice.voice.id)\" cannot be used with these settings: "
                    + error.localizedDescription
            )
        }
        try overrides.validate(for: selection.voice)
        return selection
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
