import Foundation
import SpeakDesktop
import SpeakSync

/// A snapshot of desktop sync for the host's UI.
public struct DesktopCloudSyncStatus: Equatable, Sendable {
    /// `nil` when sync can run; otherwise why it cannot (for example no API token).
    public var unavailableReason: String?
    public var isSignedIn: Bool
    public var historyEnabled: Bool
    public var apiKeyImportEnabled: Bool
    public var isSyncing: Bool
    public var lastSuccessfulSync: Date?
    public var lastError: String?

    public var summary: String {
        if let unavailableReason { return unavailableReason }
        if !isSignedIn { return "iCloud sync is off. Sign in with your Apple ID to sync History with your Mac." }
        if isSyncing { return "Syncing with iCloud…" }
        if let lastError { return "iCloud sync: \(lastError)" }
        if !historyEnabled && !apiKeyImportEnabled { return "Signed in to iCloud. Nothing is selected to sync." }
        if let lastSuccessfulSync {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Synced with iCloud at \(formatter.string(from: lastSuccessfulSync))."
        }
        return "Signed in to iCloud."
    }
}

/// What one sync pass did.
public struct DesktopCloudSyncReport: Equatable, Sendable {
    public var historyChanges: [DesktopHistorySyncChange] = []
    public var importedKeys: [String] = []
    public var removedKeys: [String] = []
    public var error: String?

    public init() {}
}

public enum DesktopCloudSyncError: Error, Equatable, Sendable {
    case unavailable(String)
    case untrustedSignInURL
    case signInNotOffered
    /// The browser did not return from Apple's sign-in page in time.
    case signInTimedOut
    /// Key import was turned on or off again while this change to it was in
    /// progress; the later change decides, and this one made no further changes.
    case keyImportSuperseded
}

extension DesktopCloudSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .untrustedSignInURL: return "iCloud offered a sign-in page that is not an Apple page; it was not opened."
        case .signInNotOffered: return "iCloud did not offer a sign-in page. Try again later."
        case .signInTimedOut: return "The browser did not return from Apple ID sign-in in time. Sign in again to retry."
        case .keyImportSuperseded: return "A later change to API-key import replaced this one."
        }
    }
}

/// CloudKit sync for a desktop host: History through the shared
/// reconciliation, and opt-in, read-only import of the API keys a Mac syncs.
///
/// A host calls `sync()` on a timer and after local History changes. One pass
/// runs at a time; a trigger during a pass runs one more complete pass after
/// it. Each pass runs in the iCloud session its account was validated in, and
/// each account-bound write — the History cursor, applied changes and
/// acknowledgements, imported keys, the key-sync key and the success time —
/// holds that session through the client's gate. None lands once a sign-out or
/// another sign-in has taken effect, or once the pass's task is cancelled;
/// writes already made stay. Turning History off stops a pass at its next
/// History step; turning key import off stops it before its next credential
/// change. Committing applied History
/// (`DesktopHistorySyncStore.persistRemoteChanges`) is not fenced: it writes
/// nothing account-bound and only reports records already saved. Key import
/// and keys saved by hand are in `DesktopCloudSyncService+Keys.swift`.
public actor DesktopCloudSyncService {
    private let resolution: DesktopCloudSyncConfiguration.Resolution
    /// Internal so tests can observe its request queue.
    let client: CloudKitWebServicesClient?
    let state: DesktopCloudSyncStateStore
    private let historyStore: DesktopHistorySyncStore
    let vault: any DesktopCredentialVault
    let envelope: EncryptedSecretEnvelope?
    private var signedIn = false
    private var syncing = false
    private var followUpRequested = false
    private var lastError: String?

    public init(
        resolution: DesktopCloudSyncConfiguration.Resolution,
        transport: any CloudKitWebServicesHTTPTransport,
        vault: any DesktopCredentialVault,
        state: DesktopCloudSyncStateStore,
        historyStore: DesktopHistorySyncStore,
        cryptography: (any SyncEnvelopeCryptography)?,
        retryPolicy: CloudKitWebRetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.resolution = resolution
        self.state = state
        self.historyStore = historyStore
        self.vault = vault
        self.envelope = cryptography.map { EncryptedSecretEnvelope(cryptography: $0) }
        if let configuration = resolution.configuration {
            client = CloudKitWebServicesClient(
                configuration: configuration,
                tokenStore: VaultWebAuthTokenStore(vault: vault),
                transport: transport,
                retryPolicy: retryPolicy,
                sleep: sleep
            )
        } else {
            client = nil
        }
    }

    /// Reads whether a stored session exists. Call once at launch.
    public func prepare() async {
        guard let client else { return }
        signedIn = (try? await client.hasWebAuthToken()) ?? false
    }

    public func status() async -> DesktopCloudSyncStatus {
        let current = await state.current
        var reason: String?
        if case .unavailable(let why) = resolution { reason = why }
        return DesktopCloudSyncStatus(
            unavailableReason: reason,
            isSignedIn: signedIn,
            historyEnabled: current.enabledFeatures.contains(.history),
            apiKeyImportEnabled: current.enabledFeatures.contains(.apiKeys),
            isSyncing: syncing,
            lastSuccessfulSync: current.lastSuccessfulSync,
            lastError: lastError
        )
    }

    // MARK: - Sign-in

    /// The Apple sign-in page to open, or `nil` when a session is already valid.
    public func signInPage() async throws -> URL? {
        let client = try requireClient()
        do {
            _ = try await client.currentUserRecordName()
            signedIn = true
            return nil
        } catch CloudKitWebServicesError.authenticationRequired(let redirect) {
            signedIn = false
            guard let redirect else { throw DesktopCloudSyncError.signInNotOffered }
            guard DesktopCloudSyncSignIn.isTrustedSignInURL(redirect) else {
                throw DesktopCloudSyncError.untrustedSignInURL
            }
            return redirect
        }
    }

    /// Completes sign-in with the token the loopback callback received.
    public func completeSignIn(webAuthToken: String) async throws {
        let client = try requireClient()
        try await client.storeWebAuthToken(webAuthToken)
        signedIn = true
        lastError = nil
    }

    /// Signs out on this device. History and imported keys stay; the account
    /// binding stays too, so signing back in as the same user resumes.
    public func signOut() async throws {
        let client = try requireClient()
        signedIn = false
        try await client.signOut()
    }

    // MARK: - Choices

    public func setHistoryEnabled(_ enabled: Bool) async throws {
        try await state.update { state in
            if enabled { state.enabledFeatures.insert(.history) } else { state.enabledFeatures.remove(.history) }
        }
    }

    // MARK: - Sync

    /// One complete pass: confirm the iCloud user, then reconcile History and
    /// import keys as enabled, and one more pass if another trigger arrived
    /// meanwhile. Errors are reported, never thrown, so a timer can call this
    /// freely; a call during a pass returns an empty report at once.
    public func sync() async -> DesktopCloudSyncReport {
        var report = DesktopCloudSyncReport()
        guard let client else {
            if case .unavailable(let reason) = resolution { report.error = reason }
            return report
        }
        guard !syncing else {
            // The running pass is followed by one more, so a change made
            // during it is not missed. Only that call validates and syncs.
            followUpRequested = true
            return report
        }
        syncing = true
        defer { syncing = false }
        var passes = 0
        repeat {
            followUpRequested = false
            let features = await state.current.enabledFeatures
            guard signedIn, !features.isEmpty else { break }
            await runPass(client: client, features: features, report: &report)
            passes += 1
        } while followUpRequested && passes < HistorySyncCoordinator.maxCoalescedPasses
        return report
    }

    /// One pass in one session: the account is validated in the session
    /// current now, and every request of the pass, and every cursor,
    /// acknowledgement, key, binding and success time it writes, happens while
    /// that session is current. Once it ends the pass writes nothing more;
    /// what it wrote before stays.
    private func runPass(
        client: CloudKitWebServicesClient,
        features: Set<CloudKitWebSyncFeature>,
        report: inout DesktopCloudSyncReport
    ) async {
        do {
            let session = await client.session()
            let fence = CloudKitWebSessionFence(client: client, session: session)
            _ = try await CloudKitWebSyncAccount.validate(
                client: client, store: state, accountBoundCursors: [state], in: session
            )
            if features.contains(.history) {
                let consent = CloudKitWebSyncConsent(enabledFeatures: features)
                try await syncHistory(client: client, fence: fence, consent: consent)
            }
            if features.contains(.apiKeys), let envelope {
                try await importKeys(client: client, fence: fence, revision: nil, envelope: envelope, report: &report)
            }
            try await admitted(fence) { try await state.update { $0.lastSuccessfulSync = Date() } }
            lastError = nil
            report.error = nil
        } catch {
            if case CloudKitWebServicesError.consentRequired(let feature) = error,
               await !state.current.enabledFeatures.contains(feature) {
                // Turned off during the pass, which stopped as asked.
                lastError = nil
                report.error = nil
                return
            }
            switch error {
            case CloudKitWebServicesError.authenticationRequired, CloudKitWebServicesError.authenticationFailed:
                // The client says whether a session remains, so a sign-in
                // that finished meanwhile is not shown as signed out.
                signedIn = (try? await client.hasWebAuthToken()) ?? false
            default:
                break
            }
            lastError = error.localizedDescription
            report.error = lastError
        }
    }

    private func syncHistory(
        client: CloudKitWebServicesClient,
        fence: CloudKitWebSessionFence,
        consent: CloudKitWebSyncConsent
    ) async throws {
        try await CloudKitWebSyncAccount.ensureSyncZone(
            for: .history, client: client, consent: consent, in: fence.session
        )
        let transport = try CloudKitWebHistorySyncTransport(client: client, consent: consent, session: fence.session)
        let coordinator = HistorySyncCoordinator(
            transport: transport,
            tokenStore: state,
            cloudAvailable: true,
            fence: DesktopHistoryPassFence(session: fence, state: state)
        )
        await coordinator.sync(store: historyStore)
        if let error = coordinator.status.error {
            throw error
        }
    }

    /// Runs account-bound work on this actor while `fence` admits it.
    func admitted<Value>(
        _ fence: any HistorySyncPassFence,
        _ work: () async throws -> Value
    ) async throws -> Value {
        try await fence.admit(isolation: self, work)
    }

    func requireClient() throws -> CloudKitWebServicesClient {
        guard let client else {
            if case .unavailable(let reason) = resolution { throw DesktopCloudSyncError.unavailable(reason) }
            throw DesktopCloudSyncError.unavailable("iCloud sync is not available.")
        }
        return client
    }
}
