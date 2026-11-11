import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package var selectedVoiceAccountInventory: VoiceAccountInventory? {
        guard let identifier = voiceOutputSettings().voiceID else { return nil }
        return VoiceAccountProvider.all.first(where: { identifier.hasPrefix($0.id + "/") })
            .flatMap { voiceDiscovery.inventories[$0] }
    }

    package func voiceCredentialDestinationIsCurrent(_ destination: VoiceOutputCredentialDestination) -> Bool {
        guard !closed else { return false }
        switch destination {
        case .selectedVoice(let epoch): return epoch == voiceCredentialEpoch
        case .explicitProvider(let context):
            return voiceAccountContextIsCurrent(context) && voiceProviderIssuedSlot != nil
        }
    }

    package func handleVoiceProviderCredential(_ message: VoiceProviderCredentialMessage) {
        guard !closed else { return }
        switch message {
        case .open(let context, let id):
            guard voiceAccountContextIsCurrent(context) else { return }
            voiceProviderIssuedSlot = nil
            beginVoiceCredentialRead(id, destination: .explicitProvider(context))
        case .cancel(let context, let id):
            guard voiceAccountContextIsCurrent(context) else { return }
            if voiceCredentialReadID == id, voiceCredentialReadDestination == .explicitProvider(context) {
                voiceCredentialReadTask?.cancel()
                voiceCredentialReadID = nil
                voiceCredentialReadDestination = nil
                voiceProviderIssuedSlot = nil
            } else if voiceCredentialWriteDestination != .explicitProvider(context)
                        || !cancelVoiceCredentialSave(id) {
                update("That account Voice key operation is no longer pending.")
            }
        case .save(let key, let request):
            beginVoiceProviderCredentialSave(key, request: request) {
                Platform.voiceProviderCredentialFinished($0, request: request)
            }
        }
    }

    package func voiceProviderCredentialPresentation(_ context: VoiceAccountCredentialContext) async
        -> Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError> {
        guard voiceAccountContextIsCurrent(context) else { return .failure(.destinationChanged) }
        let slot: VoiceOutputCredentialSlot
        do { slot = try .init(provider: context.provider) } catch { return .failure(.unavailable) }
        let effects = effects
        let lookup = Task.detached { () -> Result<Bool, VoiceOutputCredentialError> in
            guard !Task.isCancelled else { return .failure(.cancelled) }
            do { return .success(try !effects.apiKey(name: slot.identifier).isEmpty) } catch {
                return .failure(.readFailed)
            }
        }
        let result = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
        guard !closed else { return .failure(.closed) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard voiceAccountContextIsCurrent(context) else { return .failure(.destinationChanged) }
        switch result {
        case .success(let hasKey):
            voiceProviderIssuedSlot = slot
            return .success(.init(slot: slot, selectionEpoch: context.epoch, hasSavedKey: hasKey,
                canSave: canSaveVoiceCredential))
        case .failure(let error): return .failure(error)
        }
    }

    package func beginVoiceProviderCredentialSave(
        _ key: String, request: VoiceProviderCredentialRequest,
        completion: @escaping @Sendable (Result<Void, VoiceOutputCredentialError>) -> Void
    ) {
        guard !closed else { completion(voiceCredentialFailure(.closed)); return }
        guard !Task.isCancelled else { completion(voiceCredentialFailure(.cancelled)); return }
        guard voiceAccountContextIsCurrent(request.context), let issued = voiceProviderIssuedSlot else {
            completion(voiceCredentialFailure(.destinationChanged)); return
        }
        guard canSaveVoiceCredential, voiceCredentialReadTask == nil else {
            completion(voiceCredentialFailure(.busy)); return
        }
        do {
            let canonical = try VoiceOutputCredentialSlot(provider: request.context.provider)
            guard issued == canonical else { throw VoiceOutputCredentialError.destinationChanged }
            try canonical.validate(purpose: request.purpose.rawValue, identifier: request.identifier)
            let cleaned = request.operation == .remove ? "" : try canonical.validatedKey(key)
            admitVoiceCredentialWrite(cleaned, slot: canonical,
                request: .init(id: request.id, operation: request.operation,
                    destination: .explicitProvider(request.context)), completion: completion)
        } catch {
            completion(voiceCredentialFailure(error as? VoiceOutputCredentialError ?? .unavailable))
        }
    }

    package func invalidateVoiceInventory(for slot: VoiceOutputCredentialSlot) {
        for provider in VoiceAccountProvider.all
            where (try? VoiceOutputCredentialSlot(provider: provider))?.identifier == slot.identifier {
            voiceDiscovery.inventories[provider] = nil
            if voiceDiscovery.context?.provider == provider {
                voiceDiscovery.listing = nil
                voiceDiscovery.listingContext = nil
                voiceDiscovery.offeredIDs = []
            }
        }
    }
}
