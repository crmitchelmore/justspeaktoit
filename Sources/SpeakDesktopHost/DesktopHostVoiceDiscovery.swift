import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopVoiceDiscoveryState: Sendable {
    package var inventory: XAIAccountVoiceInventory?
    package var task: Task<Void, Never>?
    package var requestID: String?
    package var offeredIDs: [String] = []
    package var warning: String?
}

package struct DesktopVoiceDiscoveryPresentation: Sendable {
    package let requestID: String
    package let voices: [DesktopSpeechVoice]
    package let selected: Int
    package let message: String
    package let loading: Bool
    package let settings: DesktopVoiceOutputSettings
    package let inventory: XAIAccountVoiceInventory?
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func handleVoiceDiscovery(_ message: DesktopVoiceSourceMessage) {
        switch message {
        case .discoveryOpen(let token): openVoiceDiscovery(token)
        case .discoveryRefresh(let token): refreshVoiceDiscovery(token)
        case .discoveryClose(let token): closeVoiceDiscovery(token)
        case .discoveryChoose(let identifier, let token): chooseDiscoveredVoice(identifier, requestID: token)
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
        let inventory = currentVoiceInventory()
        do { return try voiceOutputSettings().synthesisSelection(inventory: inventory) } catch {
            if let warning = voiceDiscovery.warning,
               voiceOutputSettings().voiceID?.hasPrefix(XAITTSCatalog.voiceIDPrefix) == true {
                throw DesktopHostError(message: warning)
            }
            throw error
        }
    }

    package func openVoiceDiscovery(_ requestID: String) {
        guard !closed else { return }
        voiceDiscovery.task?.cancel()
        voiceDiscovery.requestID = requestID
        presentVoiceDiscovery("Documented presets are always available. Refresh explicitly lists voices "
            + "using the saved xAI key; no source text or synthesis request is sent.", loading: false)
    }

    package func closeVoiceDiscovery(_ requestID: String) {
        guard voiceDiscovery.requestID == requestID else { return }
        voiceDiscovery.requestID = nil
        voiceDiscovery.offeredIDs = []
        voiceDiscovery.task?.cancel()
    }

    package func refreshVoiceDiscovery(
        _ requestID: String,
        fetch: @escaping @Sendable (String) async throws -> XAIAccountVoiceInventory = { key in
            try await .fetch(credential: { key })
        }
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

    private func presentVoiceDiscovery(_ message: String, loading: Bool) {
        guard !closed, let requestID = voiceDiscovery.requestID else { return }
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
