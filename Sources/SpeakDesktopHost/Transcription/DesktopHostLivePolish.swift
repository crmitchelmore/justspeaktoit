import Foundation
import SpeakCore
import SpeakDesktop

/// Credential, route and consent policy captured before any recording suspension.
/// A failed preparation remains an explicit failed lane, never raw-as-polished.
package struct DesktopHostLivePolishInput: Sendable {
    let preferences: LivePolishPreferences
    let model: String
    let key: String
    let failure: String?
}

extension DesktopHostController {
    func livePolishSelection() -> DesktopLivePolishSelection {
        .init(configuration: settings.configuration, approved: settings.livePolishApproved == true)
    }

    // exhaustive owned live-polish admission gating; no behavior change.
    // swiftlint:disable:next cyclomatic_complexity
    func captureLivePolish(_ profile: DesktopProfileSession) -> DesktopHostLivePolishInput? {
        guard DesktopHostModels.isLive(profile.modelIdentifier) else { return nil }
        let selection = profile.livePolish ?? livePolishSelection()
        guard let configuration = selection.configuration else { return nil }
        // Instant never resolves a cleanup model or reads a cleanup credential.
        guard configuration.text("speedMode") != SpeedModeID.instant.rawValue else { return nil }
        var preferences = LivePolishPreferences(mode: .livePolish)
        var model = ""
        do {
            preferences = try configuration.livePolishPreferences
            guard selection.approved else {
                throw DesktopHostError(
                    message: "Auto-Clean is not authorized on this device. Review and Apply preferences to enable it."
                )
            }
            guard ModelCatalog.liveCapabilities(for: profile.modelIdentifier).supportedSpeedModes
                .contains(.livePolish) else { throw LivePolishError.unsupportedModel }
            if let reason = profile.skippedPolishReason { throw DesktopHostError(message: reason) }
            model = LivePolishPolicy.model(
                configured: preferences.model, postProcessing: profile.postProcessing.modelIdentifier
            )
            let mode = DesktopPostProcessing.mode(for: model)
            guard mode == .remote || mode == .localLLM else { throw LivePolishError.unsupportedModel }
            if mode == .localLLM {
                guard localCleanup != nil else {
                    throw LocalLLMError.runtimeUnavailable("This host has no downloaded-model cleanup adapter.")
                }
                return .init(preferences: preferences, model: model, key: "", failure: nil)
            }
            guard case .apiKey(let identifier, _) = ModelCredentialResolver.requirement(
                for: model, purpose: .postProcessing
            ) else { throw LivePolishError.unsupportedModel }
            let key = try effects.apiKey(name: identifier).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw LivePolishError.missingCredential }
            return .init(preferences: preferences, model: model, key: key, failure: nil)
        } catch {
            return .init(preferences: preferences, model: model, key: "", failure: error.localizedDescription)
        }
    }

    func makeLivePolish(_ input: DesktopHostLivePolishInput?, id: UUID) -> LivePolishSession? {
        guard let input else { return nil }
        let effects = effects
        let localCleanup = localCleanup
        return LivePolishSession(
            recordingID: id, preferences: input.preferences, modelIdentifier: input.model
        ) { text in
            if let failure = input.failure { throw DesktopHostError(message: failure) }
            return try await effects.polishLive(
                text: text, model: input.model, key: input.key, localLLM: localCleanup
            )
        }
    }

    func applyLivePolish(
        _ original: DesktopRecordingStore.Record, session: DesktopLiveSession
    ) async -> DesktopRecordingStore.Record {
        guard let polish = session.livePolish else { return original }
        var record = original
        guard !closed, !cancellationRequested else { polish.cancel(); return record }
        let input = record.correctedText ?? record.originalText ?? ""
        let outcome = await polish.finish(input)
        guard !closed, !cancellationRequested else { return record }
        record.livePolishResult = outcome
        if outcome.succeeded {
            record.processedText = outcome.text
            record.postProcessingModelIdentifier = outcome.modelIdentifier
        } else if let failure = outcome.failure {
            record.postProcessingFailure = "Auto-Clean failed. \(failure)"
        }
        return record
    }
}
