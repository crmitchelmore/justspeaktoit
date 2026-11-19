#if !APP_STORE
import Combine
import Foundation
import SpeakCore

/// Read-only inspection plus explicit local privacy operations. It never captures
/// analytics or changes the consent preference itself.
@MainActor
final class AnalyticsPrivacyControls: ObservableObject {
    @Published private(set) var snapshot: AnalyticsInspectionSnapshot?
    @Published private(set) var consent: AnalyticsConsentState = .unknown
    @Published private(set) var installationID: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var feedback: String?
    let policy: AnalyticsLocalPolicy
    private let controller: ProductAnalyticsController
    private let sink: PostHogProductAnalyticsSink
    private var revision = UUID()

    var collectionLabel: String {
        guard let snapshot else { return "Loading…" }
        if snapshot.isDisabled {
            return policy.isBuildDisabled ? "Disabled by build or launch policy" : "Disabled by local override"
        }
        return snapshot.isOpen && consent.permitsCollection ? "Enabled" : "Closed"
    }

    init(controller: ProductAnalyticsController, sink: PostHogProductAnalyticsSink, policy: AnalyticsLocalPolicy) {
        self.controller = controller
        self.sink = sink
        self.policy = policy
    }

    func invalidate() {
        revision = UUID()
        snapshot = nil
        installationID = nil
    }

    func refresh() async {
        let observedRevision = revision
        let consent = await controller.consentState()
        let identifier = try? await controller.existingInstallationID()
        let snapshot = await sink.inspectionSnapshot()
        guard revision == observedRevision else { return }
        self.consent = consent
        self.installationID = consent.permitsCollection && !snapshot.isDisabled ? identifier : nil
        self.snapshot = consent.permitsCollection ? snapshot : AnalyticsInspectionSnapshot(
            endpoint: snapshot.endpoint, configured: snapshot.configured, isOpen: false,
            isDisabled: snapshot.isDisabled, queueDepth: snapshot.queueDepth, records: []
        )
    }

    func setDisabled(_ disabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        feedback = nil
        defer { isBusy = false }
        policy.setLocallyDisabled(disabled)
        invalidate()
        do {
            try await controller.refreshCollectionPolicy()
            feedback = disabled
                ? "Collection disabled on this Mac." : "Local override cleared. Your consent still applies."
        } catch {
            feedback = "Local cleanup could not finish. Collection remains closed; retry the operation."
        }
        await refresh()
    }

    func resetIdentity() async {
        guard !isBusy else { return }
        isBusy = true
        feedback = nil
        defer { isBusy = false }
        invalidate()
        do {
            try await controller.resetInstallationIdentity()
            feedback = "Local identity reset. Your consent and existing server records are unchanged."
        } catch {
            feedback = "Local cleanup could not finish. Collection remains closed; retry the operation."
        }
        await refresh()
    }

    /// A nil destination means the user cancelled the native save panel.
    func export(
        to destination: URL?,
        write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) async {
        guard !isBusy, let destination else { return }
        isBusy = true
        feedback = nil
        defer { isBusy = false }
        let observedRevision = revision
        await refresh()
        guard revision == observedRevision, let snapshot else { return }
        do {
            try write(snapshot.exportData(), destination)
            feedback = "Export saved locally. Ingestion credential omitted."
        } catch {
            feedback = "The export could not be saved. Choose another location and try again."
        }
    }
}
#endif
