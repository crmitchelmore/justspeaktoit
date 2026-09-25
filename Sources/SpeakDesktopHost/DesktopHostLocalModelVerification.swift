import Foundation
import SpeakCore
import SpeakDesktop

// Recognition never runs a downloaded model whose bytes no longer match its
// pinned SHA-256. The receipt and size checks are cheap and run every time;
// the full digest runs off this actor whenever the runtime may load the file.
extension DesktopHostController where Platform: DesktopHostLocalModelPlatform {
    /// The installed file of `spec` and its identity, rehashed against the
    /// pinned digest unless it is the file verified last and is unchanged. A
    /// mismatch deletes the model, so Local models offers the download again.
    func localModelVerifiedForLoading(
        _ spec: WhisperCppModel
    ) async throws -> (file: URL, identity: LocalModelFileIdentity) {
        let installer = localInstaller
        let item = LocalModelInstaller.Item(spec)
        let (file, identity) = try installer.installedFile(for: item)
        if localModels.loadVerification.isCurrent(file, identity: identity) { return (file, identity) }
        update("Checking \(spec.displayName) against its pinned SHA-256\u{2026} Your recording is saved locally.",
               state: 2)
        // Detached, so hashing a large model never holds this actor; cancelling
        // the transcription stops it between chunks.
        let check = Task.detached(priority: .userInitiated) { try installer.verifyForLoading(item) }
        do {
            let verified = try await withTaskCancellationHandler {
                try await check.value
            } onCancel: { check.cancel() }
            localModels.loadVerification.record(file, identity: verified)
            return (file, verified)
        } catch LocalModelInstallError.checksumMismatch {
            localModels.loadVerification.forget(file)
            await releaseLoadedModel(file)
            publishLocalModels()
            throw DesktopHostError(
                message: "\(spec.displayName) no longer matches its pinned SHA-256, so it was deleted and not used. "
                    + "Download it again in Local models, then retry this recording."
            )
        }
    }

    /// Refuses a result when the model file changed while it was in use: the
    /// runtime may have loaded bytes that were never hashed, so it lets them go.
    func confirmLocalModelUnchanged(
        _ spec: WhisperCppModel, file: URL, identity: LocalModelFileIdentity
    ) async throws {
        guard LocalModelFileIdentity(fileAt: file) != identity else { return }
        localModels.loadVerification.forget(file)
        await releaseLoadedModel(file)
        throw DesktopHostError(
            message: "\(spec.displayName) changed on disk during transcription, so its transcript was not kept. "
                + "Retry this recording to check the model again."
        )
    }

    /// Frees the runtime's copy of `file`, if it holds one, off this actor.
    private func releaseLoadedModel(_ file: URL) async {
        guard let runtime = localModels.runtime else { return }
        await Task.detached { _ = runtime.releaseModel(loadedFrom: file) }.value
    }
}
