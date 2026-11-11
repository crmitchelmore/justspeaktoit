import Foundation
import SpeakDesktop

struct DesktopHostCredentialEdit: Sendable {
    let operation: @Sendable () async -> Void
    let completion: @Sendable () async -> Void
}

extension DesktopHostController {
    /// The provider key edit in flight, for hosts and tests that wait on it.
    package var providerCredentialEditTask: Task<Void, Never>? { voiceCredentials.providerEdits.task }

    /// Keyless Apply stays in settings order. A typed remote key admits owned
    /// work instead, so shutdown can drain that queue before cancelling storage.
    package func applyPostProcessingFromEditor(
        enabled: Bool, modelIdentifier: String, fields: DesktopPostProcessing.NativeFields,
        completion: @escaping @Sendable () async -> Void
    ) async {
        guard !closed, !voiceCredentials.providerEdits.stopped, !Task.isCancelled else { return }
        let operation: @Sendable () async -> Void = {
            await self.savePostProcessing(
                enabled: enabled, modelIdentifier: modelIdentifier, prompt: fields.prompt, key: fields.key,
                includeLexiconDirectives: fields.includeLexiconDirectives,
                includeContextTags: fields.includeContextTags
            )
        }
        let writesKey = DesktopPostProcessing.mode(for: modelIdentifier) == .remote
            && !fields.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if voiceCredentials.providerEdits.task != nil || writesKey {
            admitProviderCredentialEdit(operation, completion: completion)
            return
        }
        await operation()
        guard !closed, !voiceCredentials.providerEdits.stopped, !Task.isCancelled else { return }
        await completion()
    }

    package func stopProviderCredentialEdits() {
        voiceCredentials.stopProviderEdits()
    }

    func admitProviderCredentialEdit(
        _ operation: @escaping @Sendable () async -> Void,
        completion: @escaping @Sendable () async -> Void = {}
    ) {
        guard !closed, !voiceCredentials.providerEdits.stopped, !Task.isCancelled else { return }
        let edit = DesktopHostCredentialEdit(operation: operation, completion: completion)
        if voiceCredentials.providerEdits.task != nil {
            guard voiceCredentials.providerEdits.pending.count < 8 else {
                update("Too many provider key edits are pending. Wait for them to finish before retrying.")
                return
            }
            voiceCredentials.providerEdits.pending.append(edit)
            update("Provider settings queued after the current key operation.")
            return
        }
        guard !busy, recording == nil, voiceCredentials.providerEdits.task == nil,
              !voiceCredentials.isWriting else {
            update("Wait for recording and the current provider key operation to finish before retrying.")
            return
        }
        voiceCredentials.providerEdits.pending.append(edit)
        beginBusyOperation()
        voiceCredentials.providerEdits.status = "Saving provider key. Wait for this operation before recording."
        update(voiceCredentials.providerEdits.status, state: 2)
        voiceCredentials.providerEdits.task = Task { await self.completeProviderCredentialEdits() }
    }

    package func updateProviderCredentialEditor(_ status: String) {
        if voiceCredentials.providerEdits.task != nil { voiceCredentials.providerEdits.status = status }
        update(status)
    }

    private func completeProviderCredentialEdits() async {
        defer {
            voiceCredentials.providerEdits.pending.removeAll()
            voiceCredentials.providerEdits.task = nil
            finishBusyOperation()
            if !closed, !voiceCredentials.providerEdits.stopped {
                let status = Task.isCancelled
                    ? "Provider key editing was cancelled. Check saved state before retrying."
                    : voiceCredentials.providerEdits.status
                update(status, state: busy ? 2 : 0)
            }
        }
        while !closed, !voiceCredentials.providerEdits.stopped, !Task.isCancelled,
              !voiceCredentials.providerEdits.pending.isEmpty {
            let edit = voiceCredentials.providerEdits.pending.removeFirst()
            await edit.operation()
            guard !closed, !voiceCredentials.providerEdits.stopped, !Task.isCancelled else { return }
            await edit.completion()
        }
    }
}
