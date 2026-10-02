import Foundation
import SpeakCore
import SpeakDesktop

// Recognition never runs a downloaded model whose bytes do not match its
// pinned SHA-256. The receipt and size checks are cheap and run before every
// recognition; the platform runtime hashes the very bytes it loads and refuses
// them unused when they differ, so no later change to the file can reach it.
extension DesktopHostController where Platform: DesktopHostLocalModelPlatform {
    /// The runtime refused `spec`'s bytes. Deletes the model so Local models
    /// offers the download again, and returns the error the recording keeps.
    func discardMismatchedModel(_ spec: WhisperCppModel) -> DesktopHostError {
        localInstaller.discardMismatched(.init(spec))
        publishLocalModels()
        return DesktopHostError(
            message: "\(spec.displayName) no longer matches its pinned SHA-256, so it was deleted and not used. "
                + "Download it again in Local models, then retry this recording."
        )
    }
}
