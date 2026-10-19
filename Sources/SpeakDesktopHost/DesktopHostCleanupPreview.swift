import Foundation
import SpeakCore
import SpeakDesktop

/// Memory-only snapshot. Neither keys nor partial cleanup are persisted in History.
struct DesktopHostCleanupInput: Sendable {
    let options: DesktopPostProcessing.Options
    let key: String
    let failure: String?
}

extension DesktopHostController {
    func retireCleanupPresentation() {
        cleanupPresentationEpoch = UUID()
        if let ticket = cleanupNativeTicket { Platform.endCleanupPreview(ticket) }
        cleanupNativeTicket = nil
    }

    func captureCleanup(_ options: DesktopPostProcessing.Options) -> DesktopHostCleanupInput? {
        guard !closed, options.mode == .remote, options.streamingEnabled else { return nil }
        do {
            let key = try effects.apiKey(name: postProcessingCredential(for: options.modelIdentifier))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw OpenRouterClientError.apiKeyMissing }
            return .init(options: options, key: key, failure: nil)
        } catch {
            return .init(options: options, key: "", failure: error.localizedDescription)
        }
    }

    func publishCleanupPreview(
        _ text: String, recordID: UUID, requestID: UUID, presentation: UUID, nativeTicket: UInt64 = 0
    ) {
        guard !closed, !cancellationRequested, postProcessingID == requestID,
              cleanupPresentationEpoch == presentation, !comparisonVisible, !localCleanupPresenting,
              text.utf8.count <= OpenRouterChatClient.maximumStreamingTextBytes else { return }
        if selectedHistoryID == recordID, transcriptVariant == .processed {
            // Presentation only: no History mutation, clipboard or insertion.
            do { try Platform.cleanupPreview(text, ticket: nativeTicket) } catch {
                update("Cleanup preview unavailable: \(error.localizedDescription) The final result is still pending.")
            }
        }
        var state = DesktopHUDState.postProcessing
        state.liveText = String(text.suffix(DesktopHUDState.liveTextLimit))
        hud(recordID, state)
    }
}
