import Foundation
import SpeakDesktop

struct DesktopHostCredentialEdit: Sendable {
    let operation: @Sendable () async -> Void
    let completion: @Sendable () async -> Void
}

extension DesktopHostController {
    /// Keyless Apply stays in settings order. A typed remote key admits owned
    /// work instead, so shutdown can drain that queue before cancelling storage.
    package func applyPostProcessingFromEditor(
        enabled: Bool, modelIdentifier: String, fields: DesktopPostProcessing.NativeFields,
        completion: @escaping @Sendable () async -> Void
    ) async {
        guard !closed, !providerCredentialEditorsStopped, !Task.isCancelled else { return }
        let operation: @Sendable () async -> Void = {
            await self.savePostProcessing(
                enabled: enabled, modelIdentifier: modelIdentifier, prompt: fields.prompt, key: fields.key,
                includeLexiconDirectives: fields.includeLexiconDirectives,
                includeContextTags: fields.includeContextTags
            )
        }
        let writesKey = DesktopPostProcessing.mode(for: modelIdentifier) == .remote
            && !fields.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if providerCredentialEditTask != nil || writesKey {
            admitProviderCredentialEdit(operation, completion: completion)
            return
        }
        await operation()
        guard !closed, !providerCredentialEditorsStopped, !Task.isCancelled else { return }
        await completion()
    }

    package func stopProviderCredentialEdits() {
        providerCredentialEditorsStopped = true
        pendingProviderCredentialEdits.removeAll()
        providerCredentialEditTask?.cancel()
        providerCredentialWriteTask?.cancel()
    }

    func admitProviderCredentialEdit(
        _ operation: @escaping @Sendable () async -> Void,
        completion: @escaping @Sendable () async -> Void = {}
    ) {
        guard !closed, !providerCredentialEditorsStopped, !Task.isCancelled else { return }
        let edit = DesktopHostCredentialEdit(operation: operation, completion: completion)
        if providerCredentialEditTask != nil {
            guard pendingProviderCredentialEdits.count < 8 else {
                update("Too many provider key edits are pending. Wait for them to finish before retrying.")
                return
            }
            pendingProviderCredentialEdits.append(edit)
            update("Provider settings queued after the current key operation.")
            return
        }
        guard !busy, recording == nil, providerCredentialEditTask == nil,
              providerCredentialWriteTask == nil, voiceCredentialTask == nil else {
            update("Wait for recording and the current provider key operation to finish before retrying.")
            return
        }
        pendingProviderCredentialEdits.append(edit)
        beginBusyOperation()
        providerCredentialEditorStatus = "Saving provider key. Wait for this operation before recording."
        update(providerCredentialEditorStatus, state: 2)
        providerCredentialEditTask = Task { await self.completeProviderCredentialEdits() }
    }

    package func updateProviderCredentialEditor(_ status: String) {
        if providerCredentialEditTask != nil { providerCredentialEditorStatus = status }
        update(status)
    }

    private func completeProviderCredentialEdits() async {
        defer {
            pendingProviderCredentialEdits.removeAll()
            providerCredentialEditTask = nil
            finishBusyOperation()
            if !closed, !providerCredentialEditorsStopped {
                let status = Task.isCancelled
                    ? "Provider key editing was cancelled. Check saved state before retrying."
                    : providerCredentialEditorStatus
                update(status, state: busy ? 2 : 0)
            }
        }
        while !closed, !providerCredentialEditorsStopped, !Task.isCancelled,
              !pendingProviderCredentialEdits.isEmpty {
            let edit = pendingProviderCredentialEdits.removeFirst()
            await edit.operation()
            guard !closed, !providerCredentialEditorsStopped, !Task.isCancelled else { return }
            await edit.completion()
        }
    }
}
