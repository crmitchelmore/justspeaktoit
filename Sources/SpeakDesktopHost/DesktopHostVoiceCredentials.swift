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

package struct DesktopVoiceCredentialWriteRequest: Sendable {
    package let id: UUID
    package let operation: VoiceCredentialOperation
    package let destination: VoiceOutputCredentialDestination
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

    package func beginVoiceCredentialRead(_ id: UUID, destination: VoiceOutputCredentialDestination? = nil) {
        let destination = destination ?? .selectedVoice(selectionEpoch: voiceCredentialEpoch)
        voiceCredentialReadID = id
        voiceCredentialReadDestination = destination
        if let pending = voiceCredentialReadTask { pending.cancel(); return }
        activeOperations += 1
        voiceCredentialReadTask = Task {
            let result = await self.readVoiceCredentialPresentation(destination)
            self.voiceCredentialReadTask = nil
            self.finishOperation()
            self.settleVoiceAccountPresentation()
            guard !self.closed else { self.voiceCredentialReadID = nil; return }
            guard self.voiceCredentialReadID == id, self.voiceCredentialReadDestination == destination else {
                if let next = self.voiceCredentialReadID {
                    self.beginVoiceCredentialRead(next, destination: self.voiceCredentialReadDestination)
                }
                return
            }
            self.voiceCredentialReadID = nil
            self.voiceCredentialReadDestination = nil
            guard !Task.isCancelled else { return }
            switch destination {
            case .selectedVoice: Platform.voiceCredential(result, requestID: id)
            case .explicitProvider(let context):
                guard self.voiceAccountContextIsCurrent(context) else { return }
                Platform.voiceProviderCredential(result, requestID: id, context: context)
            }
        }
    }

    private func readVoiceCredentialPresentation(_ destination: VoiceOutputCredentialDestination) async
        -> Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError> {
        switch destination {
        case .selectedVoice(let epoch):
            guard epoch == voiceCredentialEpoch else { return .failure(.destinationChanged) }
            return await voiceCredentialPresentation()
        case .explicitProvider(let context): return await voiceProviderCredentialPresentation(context)
        }
    }

    package func voiceCredentialPresentation() async
        -> Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError> {
        guard !closed else { return .failure(.closed) }
        let epoch = voiceCredentialEpoch, settings = voiceOutputSettings()
        let effects = effects, cached = selectedVoiceAccountInventory
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
        guard canSaveVoiceCredential, voiceCredentialReadTask == nil else {
            completion(voiceCredentialFailure(.busy)); return
        }
        let slot: VoiceOutputCredentialSlot
        let cleaned: String
        do {
            slot = try currentVoiceCredentialSlot()
            try slot.validate(purpose: request.purpose.rawValue, identifier: request.identifier)
            cleaned = request.operation == .remove ? "" : try slot.validatedKey(key)
        } catch {
            completion(voiceCredentialFailure(error as? VoiceOutputCredentialError ?? .unavailable)); return
        }
        admitVoiceCredentialWrite(cleaned, slot: slot,
            request: .init(id: request.id, operation: request.operation,
                destination: .selectedVoice(selectionEpoch: request.selectionEpoch)), completion: completion)
    }

    package func admitVoiceCredentialWrite(
        _ cleaned: String, slot: VoiceOutputCredentialSlot, request: DesktopVoiceCredentialWriteRequest,
        completion: @escaping @Sendable (Result<Void, VoiceOutputCredentialError>) -> Void
    ) {
        activeOperations += 1
        voiceCredentialRequestID = request.id
        voiceCredentialTask = Task {
            defer {
                self.voiceCredentialTask = nil
                self.voiceCredentialRequestID = nil
                self.finishOperation()
                self.settleVoiceAccountPresentation()
            }
            do {
                try Task.checkCancellation()
                guard self.voiceCredentialDestinationIsCurrent(request.destination) else {
                    completion(self.voiceCredentialFailure(self.closed ? .closed : .destinationChanged)); return
                }
                if let saveByHand = self.cloudSync.saveKeyByHand {
                    try await saveByHand(cleaned, slot.identifier)
                } else {
                    try await Self.writeVoiceCredential(cleaned, identifier: slot.identifier)
                }
                self.invalidateVoiceInventory(for: slot)
                guard !self.closed, !Task.isCancelled else {
                    completion(.failure(.completedWhileClosing)); return
                }
                guard self.voiceCredentialDestinationIsCurrent(request.destination),
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

    package var canSaveVoiceCredential: Bool {
        !closed && !busy && recording == nil && voiceCredentialTask == nil
            && voiceTextImportTask == nil && voiceDiscovery.task == nil && voiceGenerationTask == nil
            && readAloudState.task == nil && readAloudState.exportTask == nil
            && voiceSynthesisWorkers == 0
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
        cached: VoiceAccountInventory?
    ) -> Result<(VoiceOutputCredentialSlot, Bool), VoiceOutputCredentialError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let voice: DesktopSpeechVoice
        do {
            voice = try DesktopSpeechVoice.resolved(
                modelID: settings.modelID, voiceID: settings.voiceID, accountInventory: cached)
        } catch { return .failure(.unavailable) }
        let slot: VoiceOutputCredentialSlot
        do {
            slot = try .init(voice: voice, accountInventory: cached)
        } catch { return .failure(.unavailable) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        do {
            let key = try effects.apiKey(name: slot.identifier)
            if !DesktopSpeechVoice.voices.contains(voice), cached?.matchesCredential(key) != true {
                return .failure(.unavailable)
            }
            return .success((slot, !key.isEmpty))
        } catch {
            return .failure(.readFailed)
        }
    }

    private func currentVoiceCredentialSlot() throws -> VoiceOutputCredentialSlot {
        let inventory = selectedVoiceAccountInventory
        let saved = voiceOutputSettings()
        let voice = try DesktopSpeechVoice.resolved(
            modelID: saved.modelID, voiceID: saved.voiceID, accountInventory: inventory)
        return try .init(voice: voice, accountInventory: inventory)
    }

    package func voiceCredentialFailure(_ error: VoiceOutputCredentialError)
        -> Result<Void, VoiceOutputCredentialError> {
        if !closed { update(error.localizedDescription) }
        return .failure(error)
    }
}
