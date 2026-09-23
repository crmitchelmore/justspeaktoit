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
}

extension DesktopCloudSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .untrustedSignInURL: return "iCloud offered a sign-in page that is not an Apple page; it was not opened."
        case .signInNotOffered: return "iCloud did not offer a sign-in page. Try again later."
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
/// another sign-in has taken effect, or once the pass's task is cancelled.
/// Turning History off stops a pass at its next History step; turning key
/// import off stops it before its next credential change. Committing applied
/// History (`DesktopHistorySyncStore.persistRemoteChanges`) is not fenced: it
/// writes nothing account-bound and only reports records already saved.
public actor DesktopCloudSyncService {
    private let resolution: DesktopCloudSyncConfiguration.Resolution
    /// Internal so tests can observe its request queue.
    let client: CloudKitWebServicesClient?
    private let state: DesktopCloudSyncStateStore
    private let historyStore: DesktopHistorySyncStore
    private let vault: any DesktopCredentialVault
    private let envelope: EncryptedSecretEnvelope?
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

    /// Turns on read-only API-key import: verifies the passphrase against the
    /// account, keeps only the derived key (never the passphrase) in the
    /// credential vault, and imports the keys once. It runs in one iCloud
    /// session, whose account is confirmed first; if that session ends
    /// partway, nothing is stored and no key is imported.
    public func enableKeyImport(passphrase: String) async throws -> DesktopCloudSyncReport {
        let client = try requireClient()
        guard let envelope else { throw DesktopCloudSyncError.unavailable("API-key import is not available here.") }
        let session = await client.session()
        let fence = CloudKitWebSessionFence(client: client, session: session)
        _ = try await CloudKitWebSyncAccount.validate(
            client: client, store: state, accountBoundCursors: [state], in: session
        )
        let key = try await CloudKitWebKeySync.unlock(
            passphrase: passphrase, client: client, consent: CloudKitWebSyncConsent(enabledFeatures: [.apiKeys]),
            envelope: envelope, in: session
        )
        let vault = self.vault
        try await admitted(fence) {
            try await state.update { try DesktopKeyImport.store(key, in: &$0, vault: vault) }
        }
        var report = DesktopCloudSyncReport()
        try await importKeys(client: client, fence: fence, envelope: envelope, report: &report)
        return report
    }

    /// Stops importing keys. Keys already saved on this device stay. The
    /// key-sync key goes in the same step, so no import step or newer key can
    /// fall between the two.
    public func disableKeyImport() async throws {
        let vault = self.vault
        try await state.update { state in
            try vault.deleteCredential(DesktopCloudSyncCredential.apiKeySyncKey)
            state.enabledFeatures.remove(.apiKeys)
        }
    }

    /// Records that the user saved a key by hand, so a later remote deletion
    /// of the imported value cannot remove it.
    public func noteManualKeySave(identifier: String) async {
        try? await state.update { state in
            state.importedKeys[identifier]?.isImportedValue = false
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
    /// acknowledgement, key and binding it writes, belongs to that session or
    /// does not happen. So does the success it records.
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
                try await importKeys(client: client, fence: fence, envelope: envelope, report: &report)
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

    /// Imports the synced keys in `fence`'s session. The keys are read once;
    /// then each is decided and saved in one admitted step, so a sign-out,
    /// another sign-in or turning import off stops the import before its next
    /// credential change, and a stale read never writes or deletes a key.
    private func importKeys(
        client: CloudKitWebServicesClient,
        fence: CloudKitWebSessionFence,
        envelope: EncryptedSecretEnvelope,
        report: inout DesktopCloudSyncReport
    ) async throws {
        let vault = self.vault
        guard let encoded = try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey),
              let key = Data(base64Encoded: encoded) else {
            throw CloudKitKeySyncError.missingPassphrase
        }
        let snapshot: CloudKitWebKeySyncSnapshot
        do {
            snapshot = try await CloudKitWebKeySync.read(
                key: key, client: client, consent: CloudKitWebSyncConsent(enabledFeatures: [.apiKeys]),
                envelope: envelope, in: fence.session
            )
        } catch CloudKitKeySyncError.incorrectPassphrase {
            // The passphrase changed on the Mac: ask for it again, unless a
            // newer passphrase was entered while this key was being checked.
            let forgotten = try await admitted(fence) {
                try await state.update { try DesktopKeyImport.forget(encoded, in: &$0, vault: vault) }
            }
            if forgotten { throw CloudKitKeySyncError.missingPassphrase }
            return
        }
        for secret in snapshot.secrets {
            let change = try await admitted(fence) {
                try await state.update { try DesktopKeyImport.apply(secret, to: &$0, vault: vault) }
            }
            switch change {
            case .imported?: report.importedKeys.append(secret.identifier)
            case .removed?: report.removedKeys.append(secret.identifier)
            case nil: break
            }
        }
    }

    /// Runs account-bound work on this actor while `fence` admits it.
    private func admitted<Value>(
        _ fence: any HistorySyncPassFence,
        _ work: () async throws -> Value
    ) async throws -> Value {
        try await fence.admit(isolation: self, work)
    }

    private func requireClient() throws -> CloudKitWebServicesClient {
        guard let client else {
            if case .unavailable(let reason) = resolution { throw DesktopCloudSyncError.unavailable(reason) }
            throw DesktopCloudSyncError.unavailable("iCloud sync is not available.")
        }
        return client
    }
}
