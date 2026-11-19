import Foundation

// The privacy contract spans ProductAnalyticsTaxonomy (closed property values),
// ProductAnalyticsEvent (what each event may carry), ProductAnalyticsPayload
// (the context boundary) and ProductAnalyticsController (consent and identity).

public actor ProductAnalyticsController {
    private let context: ProductAnalyticsContext
    private let sink: any ProductAnalyticsSink
    private let stateStore: any ProductAnalyticsStateStore
    private let forceDisabled: @Sendable () -> Bool
    private var consent: AnalyticsConsentState
    private var sinkIsClosed = true
    private var consentRevision = UUID()
    private var suspensionTask: Task<Void, Error>?
    private var requiresCleanupRetry = false

    public init(
        context: ProductAnalyticsContext,
        sink: any ProductAnalyticsSink,
        stateStore: any ProductAnalyticsStateStore,
        forceDisabled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        self.context = context
        self.sink = sink
        self.stateStore = stateStore
        self.forceDisabled = forceDisabled
        self.consent = try stateStore.loadConsent()
    }

    public func consentState() -> AnalyticsConsentState { consent }

    /// Applies a consent transition fail-closed: collection is only ever enabled after the new state is persisted,
    /// and every opt-out cleanup step is attempted even when an earlier step fails.
    public func setConsent(_ newConsent: AnalyticsConsentState) async throws {
        let revision = UUID()
        consentRevision = revision
        guard newConsent != .optedIn else {
            // A newer opt-in must not reopen a client whose withdrawal is still purging/closing it.
            try await awaitPendingCleanup()
            guard consentRevision == revision else { return }
            try stateStore.saveConsent(newConsent)
            guard !forceDisabled() else {
                consent = newConsent
                try await suspendCollection()
                return
            }
            try await sink.reopen()
            guard consentRevision == revision else { return }
            guard !forceDisabled() else {
                consent = newConsent
                try await suspendCollection()
                return
            }
            sinkIsClosed = false
            consent = newConsent
            return
        }
        consent = newConsent
        var firstFailure: Error?
        var shouldDeleteIdentity = true
        do {
            try stateStore.saveConsent(newConsent)
        } catch {
            firstFailure = error
            shouldDeleteIdentity = false
            do { try stateStore.resetState() } catch { firstFailure = firstFailure ?? error }
        }
        do {
            try await suspendCollection(deleteIdentity: shouldDeleteIdentity)
        } catch {
            firstFailure = firstFailure ?? error
        }
        if let firstFailure { throw firstFailure }
    }

    public func capture(_ event: ProductAnalyticsEvent) async throws {
        guard consent.permitsCollection else { return }
        let revision = consentRevision
        guard !forceDisabled() else {
            try await suspendCollection()
            return
        }
        try await awaitPendingCleanup()
        guard consentRevision == revision, consent.permitsCollection else { return }
        guard !forceDisabled() else {
            try await suspendCollection()
            return
        }
        if sinkIsClosed {
            try await sink.reopen()
            guard consentRevision == revision, consent.permitsCollection else { return }
            sinkIsClosed = false
        }
        guard !forceDisabled() else {
            try await suspendCollection()
            return
        }
        let distinctID = event.privacyClass == .pseudonymous ? try installationID() : nil
        try await sink.capture(ProductAnalyticsPayload(event: event, context: context, distinctID: distinctID))
    }

    /// Reads existing local identity without creating one or admitting an event.
    public func existingInstallationID() throws -> UUID? { try stateStore.loadInstallationID() }

    /// Invalidates admitted work before cleanup, preserving the user's consent.
    /// A future approved event may lazily create a new identity after cleanup.
    public func resetInstallationIdentity() async throws {
        consentRevision = UUID()
        try await suspendCollection()
    }

    /// Applies a changed local collection gate immediately, even without a new
    /// event. Clearing the gate never opts in or creates an identity/event.
    public func refreshCollectionPolicy() async throws {
        consentRevision = UUID()
        if forceDisabled() || requiresCleanupRetry { try await suspendCollection() }
    }

    public func preview(_ event: ProductAnalyticsEvent) throws -> Data {
        let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let payload = ProductAnalyticsPayload(
            event: event,
            context: context,
            distinctID: try stateStore.loadInstallationID() ?? zeroID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private func installationID() throws -> UUID {
        if let existing = try stateStore.loadInstallationID() { return existing }
        let id = UUID()
        try stateStore.saveInstallationID(id)
        return id
    }

    private func awaitPendingCleanup() async throws {
        if let suspensionTask { try await suspensionTask.value }
        if requiresCleanupRetry { try await suspendCollection() }
    }

    private func suspendCollection(deleteIdentity: Bool = true) async throws {
        if let suspensionTask { return try await suspensionTask.value }
        sinkIsClosed = true
        requiresCleanupRetry = true
        let cleanup = Task { try await self.performSuspension(deleteIdentity: deleteIdentity) }
        suspensionTask = cleanup
        defer { suspensionTask = nil }
        try await cleanup.value
        requiresCleanupRetry = false
    }

    private func performSuspension(deleteIdentity: Bool) async throws {
        var firstFailure: Error?
        do { try await sink.purge() } catch { firstFailure = error }
        if deleteIdentity {
            do { try stateStore.deleteInstallationID() } catch { firstFailure = firstFailure ?? error }
        }
        await sink.close()
        if let firstFailure { throw firstFailure }
    }
}
