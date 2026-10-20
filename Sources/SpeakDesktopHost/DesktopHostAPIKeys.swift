import Foundation
import SpeakCore
import SpeakDesktop

/// One API Keys page row. It carries a masked hint at most, never the secret.
package struct DesktopAPIKeyRow: Equatable, Sendable {
    package let identifier: String
    package let label: String
    package let uses: String
    package let status: String
    package let isSaved: Bool
    package let keyPageURL: String
    package let entryHint: String
}

/// What one secure-storage read found, reduced to a non-reversible hint.
package enum DesktopAPIKeyReadState: Equatable, Sendable {
    case notSet
    case saved(mask: String?)
    case unreadable
}

/// The persisted index of identifiers holding a secret, kept like the Mac's
/// `trackedKeyIdentifiers` preference. It is an index only: readiness and
/// requests always read the secure store, and the file never leaves the device.
extension DesktopHostController {
    nonisolated var trackedAPIKeysURL: URL { directory.appendingPathComponent("trackedKeyIdentifiers.json") }

    package func trackedAPIKeyIdentifiers() -> TrackedAPIKeyIdentifiers {
        guard let data = try? Data(contentsOf: trackedAPIKeysURL),
              let tracked = try? JSONDecoder().decode(TrackedAPIKeyIdentifiers.self, from: data) else {
            return TrackedAPIKeyIdentifiers()
        }
        return tracked
    }

    /// Mirrors a secure-storage write: a non-empty value registers its
    /// identifier and an empty value (a removal) forgets it.
    package func recordTrackedAPIKey(_ identifier: String, value: String) {
        var tracked = trackedAPIKeyIdentifiers()
        guard tracked.record(identifier, storedValue: value) else { return }
        persistTrackedAPIKeys(tracked)
    }

    func persistTrackedAPIKeys(_ tracked: TrackedAPIKeyIdentifiers) {
        // A failed index write is repaired by the next reconcile; the secret
        // itself is already in, or gone from, the secure store.
        try? effects.writeSettings(JSONEncoder().encode(tracked), to: trackedAPIKeysURL)
    }
}

/// The dedicated API Keys page: every credential this host's implemented
/// transcription, post-processing and Voice Output routes can use, written
/// through the same storage as the per-feature editors.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package nonisolated static func apiKeyCatalogEntries() -> [APIKeyCatalogEntry] {
        var sources: [APIKeyCatalogSource] = []
        for option in DesktopHostModels.all where !DesktopHostModels.isLocal(option.id) {
            guard let provider = DesktopHostModels.provider(for: option.id) else { continue }
            sources.append(APIKeyCatalogSource(
                identifier: provider.apiKeyIdentifier, providerName: provider.displayName,
                use: .transcription, keyPageURL: URL(string: provider.website)
            ))
        }
        sources.append(APIKeyCatalogSource(
            identifier: "openrouter.apiKey", providerName: "OpenRouter",
            use: .postProcessing, keyPageURL: OpenRouterService.apiKeysURL
        ))
        var voiceIdentifiers = Set<String>()
        for voice in DesktopSpeechVoice.voices where voiceIdentifiers.insert(voice.apiKeyIdentifier).inserted {
            guard let slot = try? VoiceOutputCredentialSlot(voice: voice, accountInventory: nil) else { continue }
            sources.append(APIKeyCatalogSource(
                identifier: slot.identifier, providerName: slot.providerName, use: .voiceOutput
            ))
        }
        for provider in VoiceAccountProvider.all {
            guard let slot = try? VoiceOutputCredentialSlot(provider: provider) else { continue }
            sources.append(APIKeyCatalogSource(
                identifier: slot.identifier, providerName: slot.providerName, use: .voiceOutput
            ))
        }
        return APIKeyCatalog.entries(sources)
    }

    /// Reads every catalogue identifier off the actor, reconciles the tracked
    /// index with what the store actually holds, and returns masked rows.
    package func apiKeyRows() async -> [DesktopAPIKeyRow] {
        let entries = Self.apiKeyCatalogEntries()
        let probed = Set(entries.map(\.identifier)).union(ModelCredentialResolver.allKnownAPIKeyIdentifiers)
        let states = await readAPIKeyStates(probed)
        if !Task.isCancelled, !closed { reconcileTrackedAPIKeys(states) }
        return entries.map { entry in
            let state = states[entry.identifier] ?? .unreadable
            let status: String
            switch state {
            case .notSet: status = "Not set"
            case .saved(let mask): status = mask.map { "Saved \($0)" } ?? "Saved"
            case .unreadable: status = "Could not read from \(Platform.credentialStoreName)"
            }
            var isSaved = false
            if case .saved = state { isSaved = true }
            return DesktopAPIKeyRow(
                identifier: entry.identifier,
                label: DesktopHostModels.uiText(entry.label),
                uses: entry.uses.summary,
                status: status,
                isSaved: isSaved,
                keyPageURL: entry.keyPageURL?.absoluteString ?? "",
                entryHint: entry.format.entryHint
            )
        }
    }

    private func readAPIKeyStates(_ identifiers: Set<String>) async -> [String: DesktopAPIKeyReadState] {
        let effects = effects
        let worker = Task.detached { () -> [String: DesktopAPIKeyReadState] in
            var states: [String: DesktopAPIKeyReadState] = [:]
            for identifier in identifiers {
                if Task.isCancelled { break }
                do {
                    let key = try effects.apiKey(name: identifier)
                    states[identifier] = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? .notSet : .saved(mask: APIKeyCatalog.maskedSuffix(key, identifier: identifier))
                } catch {
                    states[identifier] = .unreadable
                }
            }
            return states
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Unreadable identifiers keep their previous tracked state; identifiers
    /// outside the probed set are kept because they cannot be checked here.
    private func reconcileTrackedAPIKeys(_ states: [String: DesktopAPIKeyReadState]) {
        var tracked = trackedAPIKeyIdentifiers()
        var stored = tracked.identifiers.filter { states[$0] == nil || states[$0] == .unreadable }
        for (identifier, state) in states {
            if case .saved = state { stored.append(identifier) }
        }
        if tracked.reconcile(stored) { persistTrackedAPIKeys(tracked) }
    }

    /// Validates first and stores only a key the provider accepts, as the Mac does.
    @discardableResult
    package func saveAPIKey(identifier: String, key: String) async -> String {
        guard !Task.isCancelled else { return Self.apiKeysCancelledMessage }
        guard canSaveVoiceCredential else { return Self.apiKeysBusyMessage }
        guard let entry = Self.apiKeyCatalogEntries().first(where: { $0.identifier == identifier }) else {
            return report(APIKeyEntryError.unknownProvider.localizedDescription)
        }
        let cleaned: String
        do { cleaned = try APIKeyCatalog.sanitizedKey(key) } catch { return report(error.localizedDescription) }
        let validation = await checkAPIKey(cleaned, identifier: identifier)
        guard !Task.isCancelled else { return Self.apiKeysCancelledMessage }
        guard case .success = validation.outcome else { return report(Self.message(validation)) }
        guard canSaveVoiceCredential else { return Self.apiKeysBusyMessage }
        do {
            try await writeAPIKey(cleaned, identifier: identifier)
        } catch {
            return report("Failed to store key: \(error.localizedDescription)")
        }
        await apiKeyChanged(identifier)
        return report("\(entry.label) API key saved and validated successfully.")
    }

    @discardableResult
    package func removeAPIKey(identifier: String) async -> String {
        guard !Task.isCancelled else { return Self.apiKeysCancelledMessage }
        guard canSaveVoiceCredential else { return Self.apiKeysBusyMessage }
        guard let entry = Self.apiKeyCatalogEntries().first(where: { $0.identifier == identifier }) else {
            return report(APIKeyEntryError.unknownProvider.localizedDescription)
        }
        do {
            try await writeAPIKey("", identifier: identifier)
        } catch {
            return report("Failed to remove key: \(error.localizedDescription)")
        }
        await apiKeyChanged(identifier)
        return report("\(entry.label) key removed from \(Platform.credentialStoreName).")
    }

    /// Checks the typed key, or the saved key when nothing is typed. Network
    /// checks count as an operation for shutdown but never block recording.
    package func validateAPIKey(identifier: String, typed: String) async -> String {
        guard !Task.isCancelled else { return Self.apiKeysCancelledMessage }
        guard !closed else { return "Speak is closing." }
        guard let entry = Self.apiKeyCatalogEntries().first(where: { $0.identifier == identifier }) else {
            return APIKeyEntryError.unknownProvider.localizedDescription
        }
        var key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let effects = effects
            do {
                key = try await Task.detached { try effects.apiKey(name: identifier) }.value
            } catch {
                return "Could not read the \(entry.label) key from \(Platform.credentialStoreName)."
            }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "No \(entry.label) key is saved. Paste one to check it."
            }
        } else {
            do { key = try APIKeyCatalog.sanitizedKey(key) } catch { return error.localizedDescription }
        }
        guard !Task.isCancelled else { return Self.apiKeysCancelledMessage }
        let result = await checkAPIKey(key, identifier: identifier)
        guard !Task.isCancelled else { return Self.apiKeysCancelledMessage }
        return Self.message(result)
    }

    private func checkAPIKey(_ key: String, identifier: String) async -> APIKeyValidationResult {
        activeOperations += 1
        defer { finishOperation() }
        let staging = uploadStaging, endpoint = azureResourceEndpoint()
        return await APIKeyValidation.validate(
            identifier: identifier, key: key, staging: staging, azureEndpoint: endpoint
        )
    }

    /// The same write and "saved by hand" path as the per-feature editors, so
    /// both surfaces always show one stored value.
    private func writeAPIKey(_ value: String, identifier: String) async throws {
        invalidateConnectionPreWarming(resetCapture: true)
        if let saveByHand = cloudSync.saveKeyByHand {
            try await saveByHand(value, identifier)
        } else {
            try Platform.saveAPIKey(value, name: identifier)
        }
        recordTrackedAPIKey(identifier, value: value)
    }

    private func apiKeyChanged(_ identifier: String) async {
        invalidateConnectionPreWarming(resetCapture: true)
        if identifier == "openrouter.apiKey" { refreshModels(force: true) }
        if let slot = VoiceAccountProvider.all.lazy
            .compactMap({ try? VoiceOutputCredentialSlot(provider: $0) })
            .first(where: { $0.identifier == identifier }) {
            invalidateVoiceInventory(for: slot)
        }
        await refreshComparison()
    }

    private func report(_ message: String) -> String {
        update(message)
        return message
    }

    private static var apiKeysBusyMessage: String {
        "Finish recording or the current Voice Output task before changing API keys."
    }

    private static var apiKeysCancelledMessage: String { "The API key request was cancelled." }

    private static func message(_ result: APIKeyValidationResult) -> String {
        switch result.outcome {
        case .success(let message), .failure(let message): return message
        }
    }
}
