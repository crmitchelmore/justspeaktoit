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
/// The service owns the History coordinator on this actor. A host calls
/// `sync()` on a timer and after local History changes; calls are serialised
/// by the actor and a trigger during a pass queues one follow-up pass.
public actor DesktopCloudSyncService {
    private let resolution: DesktopCloudSyncConfiguration.Resolution
    private let client: CloudKitWebServicesClient?
    private let state: DesktopCloudSyncStateStore
    private let historyStore: DesktopHistorySyncStore
    private let vault: any DesktopCredentialVault
    private let envelope: EncryptedSecretEnvelope?
    private var coordinator: HistorySyncCoordinator?
    private var signedIn = false
    private var syncing = false
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
        coordinator = nil
        try await client.signOut()
    }

    // MARK: - Choices

    public func setHistoryEnabled(_ enabled: Bool) async throws {
        try await state.update { state in
            if enabled { state.enabledFeatures.insert(.history) } else { state.enabledFeatures.remove(.history) }
        }
        coordinator = nil
    }

    /// Turns on read-only API-key import: verifies the passphrase against the
    /// account, keeps only the derived key (never the passphrase) in the
    /// credential vault, and imports the keys once.
    public func enableKeyImport(passphrase: String) async throws -> DesktopCloudSyncReport {
        let client = try requireClient()
        guard let envelope else { throw DesktopCloudSyncError.unavailable("API-key import is not available here.") }
        let consent = CloudKitWebSyncConsent(enabledFeatures: [.apiKeys])
        let key = try await CloudKitWebKeySync.unlock(
            passphrase: passphrase, client: client, consent: consent, envelope: envelope
        )
        try vault.writeCredential(key.base64EncodedString(), name: DesktopCloudSyncCredential.apiKeySyncKey)
        try await state.update { $0.enabledFeatures.insert(.apiKeys) }
        var report = DesktopCloudSyncReport()
        try await importKeys(client: client, envelope: envelope, report: &report)
        return report
    }

    /// Stops importing keys. Keys already saved on this device stay.
    public func disableKeyImport() async throws {
        try await state.update { $0.enabledFeatures.remove(.apiKeys) }
        try vault.deleteCredential(DesktopCloudSyncCredential.apiKeySyncKey)
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
    /// import keys as enabled. Errors are reported, never thrown, so a timer
    /// can call this freely.
    public func sync() async -> DesktopCloudSyncReport {
        var report = DesktopCloudSyncReport()
        guard let client else {
            if case .unavailable(let reason) = resolution { report.error = reason }
            return report
        }
        let features = await state.current.enabledFeatures
        guard signedIn, !features.isEmpty else { return report }
        guard !syncing else {
            // A running History pass remembers this trigger and runs one
            // follow-up pass, so a change made during it is not missed.
            if let coordinator {
                await coordinator.sync(store: historyStore)
            }
            return report
        }
        syncing = true
        defer { syncing = false }
        do {
            try await runPass(client: client, features: features, report: &report)
            try await state.update { $0.lastSuccessfulSync = Date() }
            lastError = nil
        } catch {
            switch error {
            case CloudKitWebServicesError.authenticationRequired, CloudKitWebServicesError.authenticationFailed:
                signedIn = false
            default:
                break
            }
            lastError = error.localizedDescription
            report.error = lastError
        }
        return report
    }

    private func runPass(
        client: CloudKitWebServicesClient,
        features: Set<CloudKitWebSyncFeature>,
        report: inout DesktopCloudSyncReport
    ) async throws {
        let binding = try await CloudKitWebSyncAccount.validate(
            client: client, store: state, accountBoundCursors: [state]
        )
        if binding == .changed { coordinator = nil }
        if features.contains(.history) {
            try await syncHistory(client: client, consent: CloudKitWebSyncConsent(enabledFeatures: features))
        }
        if features.contains(.apiKeys), let envelope {
            try await importKeys(client: client, envelope: envelope, report: &report)
        }
    }

    private func syncHistory(client: CloudKitWebServicesClient, consent: CloudKitWebSyncConsent) async throws {
        try await CloudKitWebSyncAccount.ensureSyncZone(for: .history, client: client, consent: consent)
        let coordinator = try self.coordinator ?? HistorySyncCoordinator(
            transport: CloudKitWebHistorySyncTransport(client: client, consent: consent),
            tokenStore: state,
            cloudAvailable: true
        )
        self.coordinator = coordinator
        await coordinator.sync(store: historyStore)
        if let error = coordinator.status.error {
            throw error
        }
    }

    private func importKeys(
        client: CloudKitWebServicesClient,
        envelope: EncryptedSecretEnvelope,
        report: inout DesktopCloudSyncReport
    ) async throws {
        guard let encoded = try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey),
              let key = Data(base64Encoded: encoded) else {
            throw CloudKitKeySyncError.missingPassphrase
        }
        let snapshot: CloudKitWebKeySyncSnapshot
        do {
            snapshot = try await CloudKitWebKeySync.read(
                key: key, client: client, consent: CloudKitWebSyncConsent(enabledFeatures: [.apiKeys]),
                envelope: envelope
            )
        } catch CloudKitKeySyncError.incorrectPassphrase {
            // The passphrase changed on the Mac: ask for it again.
            try? vault.deleteCredential(DesktopCloudSyncCredential.apiKeySyncKey)
            try await state.update { $0.enabledFeatures.remove(.apiKeys) }
            throw CloudKitKeySyncError.missingPassphrase
        }
        let known = await state.current.importedKeys
        for secret in snapshot.secrets {
            if let seen = known[secret.identifier], seen.lastRemoteUpdate >= secret.updatedAt { continue }
            if let value = secret.value {
                try vault.writeCredential(value, name: secret.identifier)
                report.importedKeys.append(secret.identifier)
                try await remember(secret, isImportedValue: true)
            } else {
                if known[secret.identifier]?.isImportedValue == true {
                    try vault.deleteCredential(secret.identifier)
                    report.removedKeys.append(secret.identifier)
                }
                try await remember(secret, isImportedValue: false)
            }
        }
    }

    private func remember(_ secret: CloudKitWebSyncedSecret, isImportedValue: Bool) async throws {
        let entry = DesktopCloudSyncState.ImportedKey(
            lastRemoteUpdate: secret.updatedAt,
            isImportedValue: isImportedValue
        )
        try await state.update { $0.importedKeys[secret.identifier] = entry }
    }

    private func requireClient() throws -> CloudKitWebServicesClient {
        guard let client else {
            if case .unavailable(let reason) = resolution { throw DesktopCloudSyncError.unavailable(reason) }
            throw DesktopCloudSyncError.unavailable("iCloud sync is not available.")
        }
        return client
    }
}
