import Foundation
import SpeakCore
import SpeakDesktop

package typealias DesktopVoiceAccountFetcher =
    @Sendable (VoiceAccountCredentialContext, String) async throws -> VoiceAccountInventory

package enum DesktopVoiceSynthesisOwnership: Sendable {
    case none, ordinary, account
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func sameVoiceDialog(_ token: String) -> Bool {
        guard let active = voiceDiscovery.requestID else { return false }
        if let left = UUID(uuidString: active), let right = UUID(uuidString: token) { return left == right }
        return active == token
    }

    package func voiceAccountContextIsCurrent(_ context: VoiceAccountCredentialContext) -> Bool {
        let regionMatches = context.provider != .soniox
            || (voiceDiscovery.sonioxRegion != nil
                && voiceDiscovery.sonioxRegion == (try? voiceOutputSettings().validatedSonioxRegion()))
        return !closed && regionMatches && voiceDiscovery.modern && voiceDiscovery.context == context
            && sameVoiceDialog(context.sessionID.uuidString)
    }

    package func selectVoiceAccountProvider(_ proposed: VoiceAccountCredentialContext) {
        guard !closed, sameVoiceDialog(proposed.sessionID.uuidString),
              voiceDiscovery.context?.epoch != proposed.epoch,
              !voiceDiscovery.retiredEpochs.contains(proposed.epoch) else { return }
        guard voiceDiscovery.retiredEpochs.count < 256 else {
            update("Close and reopen account voices before changing provider again.")
            return
        }
        if let current = voiceDiscovery.context { voiceDiscovery.retiredEpochs.insert(current.epoch) }
        cancelVoiceProviderCredentialWork(voiceDiscovery.context)
        voiceDiscovery.context = proposed
        voiceDiscovery.sonioxRegion = try? voiceOutputSettings().validatedSonioxRegion()
        voiceDiscovery.modern = true
        voiceDiscovery.listing = nil
        voiceDiscovery.listingContext = nil
        voiceDiscovery.offeredIDs = []
        voiceProviderIssuedSlot = nil
        voiceDiscovery.task?.cancel()
        cancelAccountVoiceWork()
        presentVoiceAccountProviders()
        let regionNotice = proposed.provider == .soniox
            ? "Soniox region: \(voiceDiscovery.sonioxRegion?.displayName ?? "unsupported stored region"). "
                + "Change it in Voice Output preferences before opening this dialog. Use its matching project key. "
            : ""
        presentVoiceDiscovery(
            regionNotice + "Provider selected for this dialog only. Set its key and Refresh, then Pick "
            + "a listed voice to save the model and voice together. Source text is not sent by listing.",
            loading: voiceAccountWorkIsPending)
    }

    package func presentVoiceAccountProviders() {
        guard !closed, let context = voiceDiscovery.context else { return }
        Platform.voiceAccountProviders(.init(context: context, providers: VoiceAccountProvider.all,
            pending: voiceAccountWorkIsPending))
    }

    package func presentModernVoiceDiscovery(_ message: String, loading: Bool) {
        guard !closed, let context = voiceDiscovery.context else { return }
        voiceDiscovery.message = message
        let inventory = voiceDiscovery.listingContext == context ? voiceDiscovery.listing : nil
        let presets = context.provider.documentedPresets
        let voices = presets + (inventory?.desktopVoices ?? [])
        voiceDiscovery.offeredIDs = loading ? [] : voices.map(\.id)
        let settings = voiceOutputSettings()
        Platform.voiceDiscovery(.init(requestID: context.epoch.uuidString, voices: voices,
            selected: voices.firstIndex { $0.id == settings.voiceID } ?? -1,
            message: message, loading: loading, settings: settings, inventory: inventory?.xai,
            accountInventory: inventory))
    }

    package func refreshVoiceAccountDiscovery(
        _ epoch: String,
        fetch: DesktopVoiceAccountFetcher? = nil
    ) {
        guard let context = voiceDiscovery.context, voiceAccountContextIsCurrent(context),
              UUID(uuidString: epoch) == context.epoch else { return }
        guard !voiceAccountWorkIsPending else {
            presentVoiceDiscovery("Previous account or key work is still closing. Retry when it finishes.",
                loading: true)
            return
        }
        let region = voiceDiscovery.sonioxRegion ?? .unitedStates
        let fetch: DesktopVoiceAccountFetcher = fetch ?? { context, key in
            try await .fetch(provider: context.provider, context: context, sonioxRegion: region, credential: { key })
        }
        presentVoiceDiscovery("Listing \(context.provider.displayName) account voices. Source text is not sent.",
            loading: true)
        activeOperations += 1
        voiceDiscovery.task = Task {
            defer {
                self.voiceDiscovery.task = nil
                self.finishOperation()
                self.settleVoiceAccountPresentation()
            }
            do {
                guard let inventory = try await self.fetchVoiceAccountInventory(context, region: region, fetch: fetch)
                    else { return }
                self.voiceDiscovery.inventories[context.provider] = inventory
                self.voiceDiscovery.listing = inventory
                self.voiceDiscovery.listingContext = context
                self.presentVoiceDiscovery("Received \(inventory.desktopVoices.count) account voices. "
                    + "Only Pick saves a voice; the current saved voice is unchanged.", loading: false)
            } catch {
                guard self.voiceAccountContextIsCurrent(context) else { return }
                self.presentVoiceDiscovery(Task.isCancelled || error is CancellationError
                    ? "Listing cancelled. No new listing was accepted."
                    : "Listing failed: \(error.localizedDescription)", loading: false)
            }
        }
    }

    private func fetchVoiceAccountInventory(
        _ context: VoiceAccountCredentialContext, region: SonioxTTSRegion, fetch: DesktopVoiceAccountFetcher
    ) async throws -> VoiceAccountInventory? {
        let slot = try VoiceOutputCredentialSlot(provider: context.provider)
        let key = try await readVoiceAccountKey(slot)
        try Task.checkCancellation()
        guard voiceAccountContextIsCurrent(context) else { return nil }
        let inventory = try await fetch(context, key)
        try Task.checkCancellation()
        guard voiceAccountContextIsCurrent(context) else { return nil }
        guard inventory.provider == context.provider, inventory.matchesCredential(key),
              inventory.mistral == nil || inventory.mistral?.context == context,
              inventory.soniox == nil
                || (inventory.soniox?.context == context && inventory.soniox?.region == region) else {
            throw VoiceAccountDiscoveryError.invalidInventory(context.provider)
        }
        let currentKey = try await readVoiceAccountKey(slot)
        try Task.checkCancellation()
        guard voiceAccountContextIsCurrent(context) else { return nil }
        guard inventory.matchesCredential(currentKey) else {
            voiceDiscovery.inventories[context.provider] = nil
            throw VoiceOutputCredentialError.destinationChanged
        }
        return inventory
    }

    package func chooseVoiceAccountVoice(_ identifier: String, epoch: String) {
        guard let context = voiceDiscovery.context, voiceAccountContextIsCurrent(context),
              UUID(uuidString: epoch) == context.epoch,
              !voiceAccountWorkIsPending,
              voiceDiscovery.offeredIDs.contains(identifier) else { return }
        let inventory = voiceDiscovery.listingContext == context ? voiceDiscovery.listing : nil
        activeOperations += 1
        voiceDiscovery.task = Task {
            defer {
                self.voiceDiscovery.task = nil
                self.finishOperation()
                self.settleVoiceAccountPresentation()
            }
            do {
                let model = context.provider.modelIdentifier
                let voice = try DesktopSpeechVoice.resolved(
                    modelID: model, voiceID: identifier, accountInventory: inventory)
                if let inventory {
                    let key = try await self.readVoiceAccountKey(.init(provider: context.provider))
                    guard inventory.matchesCredential(key) else { throw VoiceOutputCredentialError.destinationChanged }
                }
                try Task.checkCancellation()
                guard self.voiceAccountContextIsCurrent(context) else { return }
                var saved = self.voiceOutputSettings()
                saved.modelID = voice.modelID
                saved.voiceID = voice.id
                guard self.persistVoiceOutput(saved, message: "Voice saved: \(voice.label).") else {
                    self.presentVoiceDiscovery("Could not save the voice. Previous settings are unchanged.",
                        loading: false)
                    return
                }
                self.presentVoiceDiscovery("Picked \(voice.name). Existing synthesis controls are preserved; "
                    + "use Normal controls if incompatible.", loading: false)
            } catch {
                guard self.voiceAccountContextIsCurrent(context) else { return }
                self.presentVoiceDiscovery("Could not pick the voice: \(error.localizedDescription)", loading: false)
            }
        }
    }

    package func readVoiceAccountKey(_ slot: VoiceOutputCredentialSlot) async throws -> String {
        let effects = effects
        let read = Task.detached {
            try Task.checkCancellation()
            do { return try slot.validatedKey(effects.apiKey(name: slot.identifier)) } catch {
                throw error as? VoiceOutputCredentialError ?? .readFailed
            }
        }
        return try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
    }

    package func cancelAccountVoiceWork() {
        guard voiceAccountWorkers > 0, let ticket = voiceAccountOutputTicket,
              playbackRequests.isCurrent(ticket) else { return }
        voiceAccountOutputTicket = nil
        voiceGenerationTask?.cancel()
        readAloudState.task?.cancel()
        readAloudState.exportTask?.cancel()
        playbackRequests.end()
        voiceOutputRecordID = nil
        Platform.stopReadAloud(&readAloudState, playback: playback)
    }

    package func beginAccountVoiceWork(
        _ selection: DesktopSpeechSelection?, ticket: DesktopPlaybackRequests.Ticket
    ) -> DesktopVoiceSynthesisOwnership {
        voiceAccountOutputTicket = nil
        if let selection, case .soniox = selection.voice { voiceDiscovery.sonioxOutputTicket = ticket } else {
            voiceDiscovery.sonioxOutputTicket = nil
        }
        guard let selection else { return .none }
        voiceSynthesisWorkers += 1
        guard !DesktopSpeechVoice.voices.contains(selection.voice) else { return .ordinary }
        voiceAccountWorkers += 1
        voiceAccountOutputTicket = ticket
        return .account
    }

    package func finishAccountVoiceWork(_ owned: DesktopVoiceSynthesisOwnership) {
        if owned != .none { voiceSynthesisWorkers -= 1 }
        if owned == .account {
            voiceAccountWorkers -= 1
            if voiceAccountWorkers == 0 { voiceAccountOutputTicket = nil }
        }
    }

    package func finishAccountVoiceOperation(
        _ owned: DesktopVoiceSynthesisOwnership, usage: DesktopVoiceUsageOperation?
    ) {
        finishAccountVoiceWork(owned)
        finishVoiceUsage(usage)
        finishOperation()
        settleVoiceAccountPresentation()
    }

    package var voiceAccountWorkIsPending: Bool {
        voiceDiscovery.task != nil || voiceCredentialTask != nil || voiceCredentialReadTask != nil
            || voiceAccountWorkers > 0
    }

    package func settleVoiceAccountPresentation() {
        guard !closed, voiceDiscovery.modern else { return }
        presentVoiceAccountProviders()
        presentModernVoiceDiscovery(voiceDiscovery.message, loading: voiceAccountWorkIsPending)
    }

    package nonisolated static func readVoiceSynthesisKey(
        effects: any DesktopHostEffects<Platform>, name: String
    ) async throws -> String {
        let lookup = Task.detached {
            try Task.checkCancellation()
            do { return try effects.apiKey(name: name) } catch { throw VoiceOutputCredentialError.readFailed }
        }
        let key = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        try Task.checkCancellation()
        return key
    }
}
