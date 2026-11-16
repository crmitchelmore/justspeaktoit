import Foundation
import SpeakCore
import SpeakDesktop

/// A host whose window is driven through the shared native window ABI. The
/// Windows and Linux hosts supply their C module's functions in these tables
/// and inherit one implementation of the presentation code below, so the two
/// windows cannot drift in what they show or report on failure.
package protocol DesktopNativeWindowPlatform: DesktopHostReadAloudPlatform {
    static var nativeWindow: DesktopNativeWindowCalls { get }
    static var nativeComparison: DesktopNativeComparisonCalls { get }
    static var nativeVoice: DesktopNativeVoiceCalls { get }
    static var nativeVoiceAccounts: DesktopNativeVoiceAccountCalls { get }
    /// Shows the saved Voice file format choices with `status`, reporting a refusal.
    static func showVoiceAudioFormats(_ settings: DesktopVoiceOutputSettings, status: String)
    /// Shows the saved Voice synthesis controls, reporting a refusal.
    static func showVoiceControls(_ settings: DesktopVoiceOutputSettings, accountInventory: VoiceAccountInventory?)
}

package extension DesktopNativeWindowPlatform {
    static var voiceConfigurationKeys: Set<String> { DesktopConfiguration.voiceTransferKeys }

    static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.exportConfiguration(voiceOutput, over: configuration)
    }

    static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.importConfiguration(from: configuration, into: &voiceOutput)
    }

    // MARK: Window presenter

    static func beginCleanupPreview() -> UInt64 { nativeWindow.beginCleanupPreview() }

    static func cleanupPreview(_ text: String, ticket: UInt64) throws {
        guard nativeWindow.cleanupPreview(text, ticket) >= 0 else {
            throw DesktopHostError(message: "\(displayName) could not enqueue the cleanup preview.")
        }
    }

    static func endCleanupPreview(_ ticket: UInt64) { nativeWindow.endCleanupPreview(ticket) }

    static func historyManagement(identifiers: [UUID]) {
        let value = identifiers.map(\.uuidString).joined(separator: "\n")
        if nativeWindow.setHistoryManagement(value) != 0 {
            update("History management could not be refreshed. Saved recordings remain on disk.")
        }
    }

    /// Shows a raw configuration action's outcome in its window, which announces it.
    static func rawConfiguration(_ outcome: DesktopRawConfigurationOutcome) {
        _ = nativeWindow.setRawConfiguration(
            outcome.text, outcome.status, outcome.issuesText, outcome.announcement, outcome.failed ? 1 : 0
        )
    }

    static func hud(_ state: DesktopHUDState) {
        _ = nativeWindow.setHUDLayout(
            state.phase.rawValue, state.headline, state.subheadline, state.liveText,
            Int32(((state.displayDuration ?? 0) * 1000).rounded()), state.compact ? 1 : 0, state.expanded ? 1 : 0
        )
    }

    static func comparisonPresentation(_ presentation: DesktopComparisonPresentation) {
        let result = nativeComparison.presentBatch(
            presentation.models, presentation.rounds, presentation.detail, presentation.selected,
            presentation.busy ? 1 : 0, presentation.recording ? 1 : 0, presentation.judgeable ? 1 : 0,
            presentation.sync.enabled ? 1 : 0, presentation.sync.available ? 1 : 0,
            presentation.references, presentation.reference,
            presentation.batch.roundID, Int32(presentation.batch.remaining), presentation.batch.canNext ? 1 : 0
        )
        guard result == 0, nativeComparison.setSaveHistory(presentation.saveToHistory ? 1 : 0) == 0 else {
            update("Comparison window is no longer open; results remain saved.")
            return
        }
    }

    // MARK: Voice Output

    static func voiceUsage(_ presentation: DesktopVoiceUsagePresentation) {
        let result = nativeVoice.setUsage(
            presentation.requestID, presentation.text, presentation.trackingEnabled ? 1 : 0
        )
        if result < 0 { update("The Voice usage report could not be shown.") }
    }

    static func voiceTextImported(_ result: Result<String, Error>, requestID: String) {
        let text: String
        let error: String
        switch result {
        case .success(let value): text = value; error = ""
        case .failure(let failure): text = ""; error = failure.localizedDescription
        }
        if nativeVoice.setTextImport(requestID, text, error) < 0 {
            update("The text import result could not be shown.")
        }
    }

    static func voiceTextImportCancelled(_ requestID: String) {
        if nativeVoice.setTextImport(requestID, "", "Text import stopped.") < 0 {
            update("The stopped text import could not be shown.")
        }
    }

    static func voiceGenerated(_ presentation: DesktopVoiceResultPresentation) {
        let result = nativeVoice.setGeneratedResult(
            presentation.resultID, presentation.working ? 1 : 0, presentation.message, presentation.format.rawValue
        )
        if result < 0 { update("The generated voice result could not be shown.") }
    }

    /// Shows the account voice listing; false when the window refused it.
    static func showVoiceAccountInventory(_ shown: DesktopVoiceDiscoveryPresentation) -> Bool {
        let labels = shown.voices.map {
            $0.label + (DesktopSpeechVoice.voices.contains($0) ? " (documented preset)" : " (account listing)")
        }.joined(separator: "\n")
        let ids = shown.voices.map(\.id).joined(separator: "\n")
        return nativeVoiceAccounts.setInventory(
            shown.requestID, labels, ids, Int32(shown.selected), shown.message, shown.loading ? 1 : 0
        ) == 0
    }

    static func voiceAccountProviders(_ presentation: DesktopVoiceAccountProvidersPresentation) {
        let providers = presentation.providers
        let selected = providers.firstIndex(of: presentation.context.provider).map(Int32.init) ?? -1
        if nativeVoiceAccounts.setProviders(
            presentation.context.sessionID.uuidString, presentation.context.epoch.uuidString,
            providers.map(\.id).joined(separator: "\n"),
            providers.map(\.displayName).joined(separator: "\n"), selected) < 0 {
            update("The account Voice providers could not be shown.")
        }
    }

    // MARK: Voice keys

    static func voiceProviderCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>,
        requestID: UUID, context: VoiceAccountCredentialContext
    ) {
        let view = DesktopVoiceCredentialView(result, requestID: requestID, credentialStore: credentialStoreName)
        if nativeVoiceAccounts.keys.setProviderCredential(
            view.requestID, context.sessionID.uuidString, context.epoch.uuidString, context.provider.id,
            view.identifier, view.label, view.privacy, view.status, view.saved, view.canSave) < 0 {
            update("The account Voice key state could not be shown.")
        }
    }

    static func voiceProviderCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceProviderCredentialRequest
    ) {
        let outcome = DesktopVoiceCredentialOutcome(result, removing: request.operation == .remove)
        if nativeVoiceAccounts.keys.finishProviderCredential(
            request.id.uuidString, request.context.sessionID.uuidString,
            request.context.epoch.uuidString, request.context.provider.id, outcome.success, outcome.message) < 0 {
            update("The account Voice key operation result could not be shown.")
        }
    }

    static func voiceCredential(
        _ result: Result<DesktopVoiceCredentialPresentation, VoiceOutputCredentialError>, requestID: UUID
    ) {
        let view = DesktopVoiceCredentialView(result, requestID: requestID, credentialStore: credentialStoreName)
        if nativeVoiceAccounts.keys.setCredential(
            view.requestID, view.selectionEpoch, view.identifier, view.label, view.privacy, view.status,
            view.saved, view.canSave) < 0 {
            update("The Voice provider key state could not be shown.")
        }
    }

    static func voiceCredentialFinished(
        _ result: Result<Void, VoiceOutputCredentialError>, request: VoiceOutputCredentialRequest
    ) {
        let outcome = DesktopVoiceCredentialOutcome(result, removing: request.operation == .remove)
        if nativeVoiceAccounts.keys.finishCredential(
            request.id.uuidString, request.selectionEpoch.uuidString, outcome.success, outcome.message) < 0 {
            update("The Voice provider key operation result could not be shown.")
        }
    }
}
