import Foundation
import SpeakDesktop
import SpeakSync

extension DesktopCloudSyncService {
    public func installComparisonStore(_ store: DesktopComparisonStore) {
        comparisonStore = store
    }

    public func setComparisonEnabled(_ enabled: Bool) async throws {
        try await state.setComparisonConsent(enabled)
    }

    func syncComparisons(
        client: CloudKitWebServicesClient, fence: CloudKitWebSessionFence, features: Set<CloudKitWebSyncFeature>
    ) async throws {
        guard let comparisonStore, let account = await state.current.boundAccount else {
            throw DesktopCloudSyncError.unavailable("Comparison storage is not available for this sync session.")
        }
        let consent = CloudKitWebSyncConsent(enabledFeatures: features)
        let scope = DesktopComparisonSyncScope(account: account, consentRevision: await state.comparisonConsentRevision)
        let transport = try CloudKitWebComparisonSyncTransport(
            client: client, consent: consent, session: fence.session
        ) { [state] in
            try Task.checkCancellation()
            let current = await state.current
            guard current.boundAccount == account else { throw CloudKitWebServicesError.sessionChanged }
            try await state.requireComparisonConsent(revision: scope.consentRevision)
        }
        let pass = DesktopComparisonSyncPass(
            transport: transport, fence: fence, state: state, store: comparisonStore, scope: scope
        )
        let coordinator = ComparisonSyncCoordinator(
            transport: pass, tokenStore: pass, cloudAvailability: { true }
        )
        try await pass.check()
        try await CloudKitWebSyncAccount.ensureSyncZone(
            for: .comparisonRounds, client: client, consent: consent, in: fence.session
        )
        await coordinator.sync(store: pass)
        try await pass.check()
        if let error = coordinator.status.lastError { throw error }
    }

}

struct DesktopComparisonSyncScope: Sendable {
    let account: String
    let consentRevision: UInt64
}

struct DesktopComparisonConsentSuperseded: LocalizedError {
    var errorDescription: String? { "A later comparison-sync choice replaced this pass." }
}

struct DesktopComparisonConsentSaveFailure: LocalizedError {
    let detail: String
    var errorDescription: String? {
        "Comparison sync is disabled for this run, but the choice could not be saved. Retry before relaunch: \(detail)"
    }
}
