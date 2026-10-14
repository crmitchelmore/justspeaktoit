import SpeakDesktopSync

package struct DesktopHostComparisonSyncHooks: Sendable {
    package var status: @Sendable () async -> DesktopCloudSyncStatus
    package var setEnabled: @Sendable (Bool) async throws -> Void
    package var changed: @Sendable () -> Void
}

extension DesktopHostController {
    func comparisonSupplementEvent(_ event: Int32, text: String, index: Int32) async -> Bool {
        switch event {
        case 109, 120: comparisonMaintenanceEvent(event, text: text)
        case 121, 122: await comparisonSyncEvent(event, enabled: index != 0)
        case 123:
            comparisonVisible = false
            await cancelComparison()
        case 124, 125: await comparisonPreferenceEvent(event, text: text, live: index == 1)
        case 128: await nextComparisonFile(text)
        default: return false
        }
        return true
    }

    package func installComparisonSync(_ hooks: DesktopHostComparisonSyncHooks) {
        guard !closed else { return }
        comparisonSync = hooks
    }

    func comparisonSyncEvent(_ event: Int32, enabled: Bool) async {
        guard !closed, let comparisonSync else {
            comparisonStatus("Comparison sync is unavailable. Configure iCloud Sync in Settings.")
            return
        }
        do {
            if event == 121 { try await comparisonSync.setEnabled(enabled) }
            comparisonSync.changed()
        } catch {
            comparisonStatus("Comparison sync: \(error.localizedDescription)")
        }
    }

    func comparisonSyncPresentation() async -> (status: String, controls: DesktopComparisonSyncControls) {
        guard let comparisonSync else {
            return ("Comparison sync is unavailable on this host.", .init())
        }
        let status = await comparisonSync.status()
        let summary = status.unavailableReason
            ?? (status.comparisonEnabled ? status.summary : "Comparison sync is off.")
        let signIn = status.isSignedIn ? "" : " Sign in from iCloud Sync settings."
        return (
            summary + signIn
                + "\nOpt-in sync includes transcripts, model identities and rankings; never audio or keys.",
            .init(enabled: status.comparisonEnabled, available: status.unavailableReason == nil)
        )
    }
}

package struct DesktopComparisonSyncControls: Sendable {
    package var enabled = false
    package var available = false
}
