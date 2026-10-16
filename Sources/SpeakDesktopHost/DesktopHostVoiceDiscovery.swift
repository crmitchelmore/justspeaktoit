import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopVoiceDiscoveryState: Sendable {
    package var inventories: [VoiceAccountProvider: VoiceAccountInventory] = [:]
    package var inventory: XAIAccountVoiceInventory? {
        get { inventories[.xai]?.xai }
        set { inventories[.xai] = newValue.map(VoiceAccountInventory.xai) }
    }
    package var context: VoiceAccountCredentialContext?
    package var sonioxRegion: SonioxTTSRegion?
    package var sonioxOutputTicket: DesktopPlaybackRequests.Ticket?
    package var modern = false
    package var retiredEpochs: Set<UUID> = []
    package var listing: VoiceAccountInventory?
    package var listingContext: VoiceAccountCredentialContext?
    package var task: Task<Void, Never>?
    package var requestID: String?
    package var offeredIDs: [String] = []
    package var warning: String?
    package var message = ""
    package var actionID: String? { modern ? context?.epoch.uuidString : requestID }
    package var provider: VoiceAccountProvider { context?.provider ?? .xai }
}

package struct DesktopVoiceDiscoveryPresentation: Sendable {
    package let requestID: String
    package let voices: [DesktopSpeechVoice]
    package let selected: Int
    package let message: String
    package let loading: Bool
    package let settings: DesktopVoiceOutputSettings
    package let inventory: XAIAccountVoiceInventory?
    package var accountInventory: VoiceAccountInventory?
}

package struct DesktopVoiceAccountProvidersPresentation: Sendable {
    package let context: VoiceAccountCredentialContext
    package let providers: [VoiceAccountProvider]
    package let pending: Bool
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func handleVoiceDiscovery(_ message: DesktopVoiceSourceMessage) {
        switch message {
        case .discoveryOpen(let token): openVoiceDiscovery(token)
        case .discoveryOpenModern(let session): openModernVoiceDiscovery(session)
        case .discoveryRefresh(let token): refreshVoiceDiscovery(token)
        case .discoveryClose(let token): closeVoiceDiscovery(token)
        case .discoveryChoose(let identifier, let token): chooseDiscoveredVoice(identifier, requestID: token)
        case .discoveryProvider(let context): selectVoiceAccountProvider(context)
        default: update("The native account voice action is invalid.")
        }
    }

    package func currentVoiceInventory() -> XAIAccountVoiceInventory? {
        guard let inventory = voiceDiscovery.inventory else { return nil }
        do {
            guard inventory.matchesCredential(try effects.apiKey(name: XAITTSCatalog.credentialIdentifier)) else {
                voiceDiscovery.inventory = nil
                voiceDiscovery.warning = XAIAccountVoiceDiscoveryError.credentialChanged.localizedDescription
                return nil
            }
            return inventory
        } catch {
            voiceDiscovery.inventory = nil
            voiceDiscovery.warning = "Account voices unavailable: \(error.localizedDescription). Refresh to retry."
            return nil
        }
    }

    package func currentVoiceSelection() throws -> DesktopSpeechSelection {
        let saved = voiceOutputSettings()
        let inventory: VoiceAccountInventory?
        if saved.voiceID?.hasPrefix(MistralTTSCatalog.voiceIDPrefix) == true {
            inventory = voiceDiscovery.inventories[.mistral]
        } else { inventory = selectedVoiceAccountInventory }
        do {
            let selection = try saved.synthesisSelection(accountInventory: inventory)
            if !DesktopSpeechVoice.voices.contains(selection.voice), voiceAccountWorkers > 0 {
                throw VoiceOutputCredentialError.busy
            }
            return selection
        } catch {
            if let warning = voiceDiscovery.warning,
               voiceOutputSettings().voiceID?.hasPrefix(XAITTSCatalog.voiceIDPrefix) == true {
                throw DesktopHostError(message: warning)
            }
            throw error
        }
    }

    package func openVoiceDiscovery(_ requestID: String) {
        guard !closed else { return }
        resetVoiceDiscoveryDialog(requestID, modern: false, context: UUID(uuidString: requestID).map {
            .init(provider: .xai, sessionID: $0, epoch: UUID())
        })
        presentVoiceAccountProviders()
        presentVoiceDiscovery("Documented presets are always available. Refresh explicitly lists voices "
            + "using the saved xAI key; no source text or synthesis request is sent.", loading: false)
    }

    package func openModernVoiceDiscovery(_ sessionID: UUID) {
        guard !closed else { return }
        let context = VoiceAccountCredentialContext(provider: .xai, sessionID: sessionID, epoch: UUID())
        resetVoiceDiscoveryDialog(sessionID.uuidString, modern: true, context: context)
        presentVoiceAccountProviders()
        presentModernVoiceDiscovery("Choose an account provider, then explicitly set its key or Refresh. "
            + "Only Pick saves a voice. No key lookup, listing or synthesis is started by opening this dialog.",
            loading: voiceAccountWorkIsPending)
    }

    private func resetVoiceDiscoveryDialog(
        _ requestID: String, modern: Bool, context: VoiceAccountCredentialContext?
    ) {
        cancelVoiceProviderCredentialWork(voiceDiscovery.context)
        cancelAccountVoiceWork()
        voiceDiscovery.task?.cancel()
        voiceProviderIssuedSlot = nil
        voiceDiscovery.requestID = requestID
        voiceDiscovery.modern = modern
        voiceDiscovery.retiredEpochs = []
        voiceDiscovery.listing = nil
        voiceDiscovery.listingContext = nil
        voiceDiscovery.context = context
        voiceDiscovery.offeredIDs = []
    }

    package func closeVoiceDiscovery(_ requestID: String) {
        guard sameVoiceDialog(requestID) else { return }
        cancelVoiceProviderCredentialWork(voiceDiscovery.context)
        cancelAccountVoiceWork()
        voiceDiscovery.requestID = nil
        voiceDiscovery.context = nil
        voiceDiscovery.listing = nil
        voiceDiscovery.listingContext = nil
        voiceProviderIssuedSlot = nil
        voiceDiscovery.offeredIDs = []
        voiceDiscovery.task?.cancel()
    }

    package func refreshVoiceDiscovery(
        _ requestID: String,
        fetch: @escaping @Sendable (String) async throws -> XAIAccountVoiceInventory = { key in
            try await .fetch(credential: { key })
        }
    ) {
        if voiceDiscovery.modern {
            refreshVoiceAccountDiscovery(requestID)
            return
        }
        refreshLegacyVoiceDiscovery(requestID, fetch: fetch)
    }

    private func refreshLegacyVoiceDiscovery(
        _ requestID: String, fetch: @escaping @Sendable (String) async throws -> XAIAccountVoiceInventory
    ) {
        guard !closed, voiceDiscovery.requestID == requestID else { return }
        guard voiceDiscovery.task == nil else {
            presentVoiceDiscovery("The previous listing is still closing. Retry Refresh when it finishes.",
                                  loading: false)
            return
        }
        let key: String
        do {
            key = try effects.apiKey(name: XAITTSCatalog.credentialIdentifier)
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DesktopXAISpeechError.missingCredential
            }
        } catch {
            voiceDiscovery.inventory = nil
            presentVoiceDiscovery(error.localizedDescription, loading: false)
            return
        }
        _ = currentVoiceInventory()
        presentVoiceDiscovery("Listing xAI account voices. Close cancels; source text is not sent.", loading: true)
        activeOperations += 1
        voiceDiscovery.task = Task {
            defer {
                self.voiceDiscovery.task = nil
                self.finishOperation()
            }
            do {
                let inventory = try await fetch(key)
                try Task.checkCancellation()
                guard !self.closed, self.voiceDiscovery.requestID == requestID else { return }
                guard inventory.matchesCredential(
                    try self.effects.apiKey(name: XAITTSCatalog.credentialIdentifier)
                ) else {
                    self.voiceDiscovery.inventory = nil
                    throw XAIAccountVoiceDiscoveryError.credentialChanged
                }
                self.voiceDiscovery.inventory = inventory
                self.voiceDiscovery.warning = nil
                self.presentVoiceDiscovery("Listing received: \(inventory.voices.count) additional account voices. "
                    + "Documented presets are labelled separately.", loading: false)
            } catch is CancellationError {
                guard !self.closed, self.voiceDiscovery.requestID == requestID else { return }
                self.presentVoiceDiscovery("Listing cancelled. No new listing was accepted.", loading: false)
            } catch {
                guard !self.closed, self.voiceDiscovery.requestID == requestID else { return }
                let retained = self.currentVoiceInventory() != nil
                self.presentVoiceDiscovery(error.localizedDescription
                    + (retained ? " Previous same-key listing retained; this refresh failed." : ""),
                    loading: false)
            }
        }
    }

    package func chooseDiscoveredVoice(_ identifier: String, requestID: String) {
        if voiceDiscovery.modern {
            chooseVoiceAccountVoice(identifier, epoch: requestID)
            return
        }
        guard !closed, voiceDiscovery.requestID == requestID, voiceDiscovery.task == nil,
              voiceDiscovery.offeredIDs.contains(identifier) else { return }
        do {
            let voice = try DesktopSpeechVoice.resolved(modelID: XAITTSCatalog.providerIdentifier,
                voiceID: identifier, xaiInventory: currentVoiceInventory())
            var changed = voiceOutputSettings()
            changed.modelID = voice.modelID
            changed.voiceID = voice.id
            guard persistVoiceOutput(changed, message: "Voice saved: \(voice.label).") else {
                presentVoiceDiscovery("Could not save the voice. Previous settings are unchanged.", loading: false)
                return
            }
            presentVoiceDiscovery("Selected \(voice.name). Existing synthesis controls are preserved; "
                + "use Normal controls if incompatible. Read, Generate and Export text use this voice.",
                loading: false)
        } catch {
            presentVoiceDiscovery(error.localizedDescription, loading: false)
        }
    }

    package func presentVoiceDiscovery(_ message: String, loading: Bool) {
        guard !closed, let requestID = voiceDiscovery.requestID else { return }
        if voiceDiscovery.modern {
            presentModernVoiceDiscovery(message, loading: loading)
            return
        }
        let inventory = currentVoiceInventory()
        let voices = XAITTSCatalog.voices.map(DesktopSpeechVoice.xai) + (inventory?.desktopVoices ?? [])
        voiceDiscovery.offeredIDs = voices.map(\.id)
        let settings = voiceOutputSettings()
        Platform.voiceDiscovery(.init(requestID: requestID, voices: voices,
            selected: voices.firstIndex { $0.id == settings.voiceID } ?? -1,
            message: message + (voiceDiscovery.warning.map { "\n" + $0 } ?? ""),
            loading: loading, settings: settings, inventory: inventory))
    }
}
