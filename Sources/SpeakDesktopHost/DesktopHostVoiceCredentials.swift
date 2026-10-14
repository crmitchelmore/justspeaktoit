import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopVoiceCredentialPresentation: Equatable, Sendable {
    package let slot: VoiceOutputCredentialSlot
    package let selectionEpoch: UUID
    package let hasSavedKey: Bool
    package let canSave: Bool

    package init(slot: VoiceOutputCredentialSlot, selectionEpoch: UUID, hasSavedKey: Bool, canSave: Bool) {
        self.slot = slot
        self.selectionEpoch = selectionEpoch
        self.hasSavedKey = hasSavedKey
        self.canSave = canSave
    }
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package func handleVoiceCredential(_ message: VoiceOutputCredentialMessage) {
        guard !closed else { return }
        switch message {
        case .open(let id):
            beginVoiceCredentialRead(id)
        case .cancel(let id):
            if voiceCredentialReadID == id {
                voiceCredentialReadTask?.cancel()
                voiceCredentialReadID = nil
            } else if !cancelVoiceCredentialSave(id) {
                update("That Voice key operation is no longer pending.")
            }
        case .save(let key, let request):
            beginVoiceCredentialSave(key, request: request) {
                Platform.voiceCredentialFinished($0, request: request)
            }
        }
    }

    private func beginVoiceCredentialRead(_ id: UUID) {
        voiceCredentialReadID = id
        if let pending = voiceCredentialReadTask { pending.cancel(); return }
        activeOperations += 1
        voiceCredentialReadTask = Task {
            let result = await self.voiceCredentialPresentation()
            self.voiceCredentialReadTask = nil
            self.finishOperation()
            guard !self.closed else { self.voiceCredentialReadID = nil; return }
            guard self.voiceCredentialReadID == id else {
                if let next = self.voiceCredentialReadID { self.beginVoiceCredentialRead(next) }
                return
            }
            self.voiceCredentialReadID = nil
            guard !Task.isCancelled else { return }
            Platform.voiceCredential(result, requestID: id)
        }
    }

    package func voiceCredentialPresentation() async
        -> Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError> {
        guard !closed else { return .failure(.closed) }
        let epoch = voiceCredentialEpoch, settings = voiceOutputSettings()
        let effects = effects, cached = voiceDiscovery.inventory
        let lookup = Task.detached {
            Self.lookupVoiceCredential(settings: settings, effects: effects, cached: cached)
        }
        let result = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
        guard !closed else { return .failure(.closed) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard epoch == voiceCredentialEpoch else { return .failure(.destinationChanged) }
        switch result {
        case .success(let (slot, hasSavedKey)):
            return .success(.init(
                slot: slot, selectionEpoch: voiceCredentialEpoch, hasSavedKey: hasSavedKey,
                canSave: canSaveVoiceCredential))
        case .failure(let error): return .failure(error)
        }
    }

    package func beginVoiceCredentialSave(
        _ key: String, request: VoiceOutputCredentialRequest,
        completion: @escaping @Sendable (Result<Void, VoiceOutputCredentialError>) -> Void
    ) {
        guard !closed else { completion(voiceCredentialFailure(.closed)); return }
        guard !Task.isCancelled else { completion(voiceCredentialFailure(.cancelled)); return }
        guard request.selectionEpoch == voiceCredentialEpoch else {
            completion(voiceCredentialFailure(.destinationChanged)); return
        }
        guard canSaveVoiceCredential else { completion(voiceCredentialFailure(.busy)); return }
        let slot: VoiceOutputCredentialSlot
        let cleaned: String
        do {
            slot = try currentVoiceCredentialSlot()
            try slot.validate(purpose: request.purpose.rawValue, identifier: request.identifier)
            cleaned = request.operation == .remove ? "" : try slot.validatedKey(key)
        } catch {
            completion(voiceCredentialFailure(error as? VoiceOutputCredentialError ?? .unavailable)); return
        }
        activeOperations += 1
        voiceCredentialRequestID = request.id
        voiceCredentialTask = Task {
            defer {
                self.voiceCredentialTask = nil
                self.voiceCredentialRequestID = nil
                self.finishOperation()
            }
            do {
                try Task.checkCancellation()
                guard !self.closed, request.selectionEpoch == self.voiceCredentialEpoch else {
                    completion(self.voiceCredentialFailure(self.closed ? .closed : .destinationChanged)); return
                }
                if let saveByHand = self.cloudSync.saveKeyByHand {
                    try await saveByHand(cleaned, slot.identifier)
                } else {
                    try await Self.writeVoiceCredential(cleaned, identifier: slot.identifier)
                }
                guard !self.closed, !Task.isCancelled else {
                    completion(.failure(.completedWhileClosing)); return
                }
                guard request.selectionEpoch == self.voiceCredentialEpoch,
                      self.voiceCredentialRequestID == request.id else {
                    completion(.failure(.completedForPreviousSelection)); return
                }
                self.update(request.operation == .remove ? "\(slot.providerName) Voice Output key removed."
                    : "\(slot.providerName) Voice Output key saved in \(Platform.credentialStoreName).")
                completion(.success(()))
            } catch {
                completion(self.voiceCredentialFailure(
                    Task.isCancelled || error is CancellationError ? .cancelled : .saveFailed))
            }
        }
    }

    package func cancelVoiceCredentialSave(_ requestID: UUID) -> Bool {
        guard voiceCredentialRequestID == requestID else { return false }
        voiceCredentialTask?.cancel()
        return true
    }

    private var canSaveVoiceCredential: Bool {
        !closed && !busy && recording == nil && voiceCredentialTask == nil
            && voiceTextImportTask == nil && voiceDiscovery.task == nil && voiceGenerationTask == nil
            && readAloudState.task == nil && readAloudState.exportTask == nil
    }

    private nonisolated static func writeVoiceCredential(_ key: String, identifier: String) async throws {
        let write = Task.detached {
            try Task.checkCancellation()
            try Platform.saveAPIKey(key, name: identifier)
        }
        try await withTaskCancellationHandler { try await write.value } onCancel: { write.cancel() }
    }

    private nonisolated static func lookupVoiceCredential(
        settings: DesktopVoiceOutputSettings, effects: any DesktopHostEffects<Platform>,
        cached: XAIAccountVoiceInventory?
    ) -> Result<(VoiceOutputCredentialSlot, Bool), VoiceOutputCredentialError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let voice: DesktopSpeechVoice
        do {
            voice = try DesktopSpeechVoice.resolved(
                modelID: settings.modelID, voiceID: settings.voiceID, xaiInventory: cached)
        } catch { return .failure(.unavailable) }
        var inventory = cached
        if case .xai = voice, let cached {
            do {
                if !cached.matchesCredential(try effects.apiKey(name: XAITTSCatalog.credentialIdentifier)) {
                    inventory = nil
                }
            } catch { return .failure(.readFailed) }
        }
        let slot: VoiceOutputCredentialSlot
        do {
            slot = try .init(voice: voice, inventory: inventory)
        } catch { return .failure(.unavailable) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        do { return .success((slot, try !effects.apiKey(name: slot.identifier).isEmpty)) } catch {
            return .failure(.readFailed)
        }
    }

    private func currentVoiceCredentialSlot() throws -> VoiceOutputCredentialSlot {
        let inventory = voiceDiscovery.inventory
        let saved = voiceOutputSettings()
        let voice = try DesktopSpeechVoice.resolved(
            modelID: saved.modelID, voiceID: saved.voiceID, xaiInventory: inventory)
        return try .init(voice: voice, inventory: inventory)
    }

    private func voiceCredentialFailure(_ error: VoiceOutputCredentialError)
        -> Result<Void, VoiceOutputCredentialError> {
        if !closed { update(error.localizedDescription) }
        return .failure(error)
    }
}
