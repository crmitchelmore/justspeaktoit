import Foundation

extension DesktopHostController {
    /// Native vault calls may outlive cancellation. Keep their writer slot until
    /// the actual call returns, without holding the Host actor or shutdown open.
    func writeProviderAPIKey(_ value: String, identifier: String) async throws {
        guard !closed else { throw DesktopHostError(message: "Speak is closing.") }
        try Task.checkCancellation()
        guard providerCredentialWriteTask == nil, voiceCredentialTask == nil else {
            throw DesktopHostError(message: "Wait for the current provider key operation to finish before retrying.")
        }
        invalidateConnectionPreWarming(resetCapture: true)
        activeOperations += 1
        let saveByHand = cloudSync.saveKeyByHand
        let worker = Task.detached {
            try Task.checkCancellation()
            do {
                if let saveByHand {
                    try await saveByHand(value, identifier)
                } else {
                    try Platform.saveAPIKey(value, name: identifier)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DesktopHostError(
                    message: "The provider key write could not be confirmed. "
                        + "Check the credential store before retrying."
                )
            }
        }
        providerCredentialWriteTask = worker
        defer {
            providerCredentialWriteTask = nil
            finishOperation()
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        invalidateConnectionPreWarming(resetCapture: true)
        recordTrackedAPIKey(identifier, value: value)
    }
}
