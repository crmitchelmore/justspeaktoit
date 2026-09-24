import Foundation
import SpeakSync

// API-key import and keys saved by hand. Every credential change is one step
// of the sync state (`DesktopKeyImport`), so it cannot interleave with another.
// Import runs in one validated iCloud session, and turning it on or off is
// ordered by a revision, so the user's latest change decides the result.
extension DesktopCloudSyncService {
    /// Turns on read-only API-key import: verifies the passphrase against the
    /// account, keeps only the derived key (never the passphrase) in the
    /// credential vault, and imports the keys once, all in one iCloud session
    /// whose account is confirmed first. Turning import on or off again while
    /// this runs supersedes it, and it then throws `keyImportSuperseded`. Once
    /// its session has ended or it has been superseded it makes no further
    /// change; changes it already made are not undone.
    public func enableKeyImport(passphrase: String) async throws -> DesktopCloudSyncReport {
        let client = try requireClient()
        guard let envelope else { throw DesktopCloudSyncError.unavailable("API-key import is not available here.") }
        let revision = await state.claimKeyImportRevision()
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
            try await state.update(forKeyImportRevision: revision) {
                try DesktopKeyImport.store(key, in: &$0, vault: vault)
            }
        }
        var report = DesktopCloudSyncReport()
        try await importKeys(client: client, fence: fence, revision: revision, envelope: envelope, report: &report)
        return report
    }

    /// Stops importing keys and supersedes a turn-on still in progress. Keys
    /// already saved on this device stay. The key-sync key goes in the same
    /// step, so no import step or newer key can fall between the two.
    public func disableKeyImport() async throws {
        let vault = self.vault
        try await state.updateClaimingKeyImport { state in
            try vault.deleteCredential(DesktopCloudSyncCredential.apiKeySyncKey)
            state.enabledFeatures.remove(.apiKeys)
        }
    }

    /// Saves a key the user typed, or removes it when `value` is empty, and
    /// marks it saved by hand, in one step, so no import step falls between
    /// the two: a remote deletion never removes it, and a newer remote value
    /// still replaces it, as it replaces any saved key. The mark is saved
    /// first; if the sync state cannot be saved, this throws and the key is
    /// left as it was.
    public func saveKeyByHand(_ value: String, identifier: String) async throws {
        try await DesktopKeyImport.saveByHand(value, identifier: identifier, in: state, vault: vault)
    }

    /// Records that the user saved a key by hand, so a later remote deletion
    /// of the imported value cannot remove it. `saveKeyByHand` does this in
    /// the same step as saving the key, with no gap for an import step.
    public func noteManualKeySave(identifier: String) async {
        try? await state.update { state in
            state.importedKeys[identifier]?.isImportedValue = false
        }
    }

    /// Imports the synced keys in `fence`'s session. The keys are read once;
    /// then each is decided and saved in one admitted step, so a sign-out,
    /// another sign-in or turning import off stops the import before its next
    /// credential change, and a stale read never writes or deletes a key.
    /// With a `revision`, the import belongs to that change to key import and
    /// also stops once a later one begins.
    func importKeys(
        client: CloudKitWebServicesClient,
        fence: CloudKitWebSessionFence,
        revision: UInt64?,
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
                try await updateKeys(revision) { try DesktopKeyImport.forget(encoded, in: &$0, vault: vault) }
            }
            if forgotten { throw CloudKitKeySyncError.missingPassphrase }
            return
        }
        for secret in snapshot.secrets {
            let change = try await admitted(fence) {
                try await updateKeys(revision) { try DesktopKeyImport.apply(secret, to: &$0, vault: vault) }
            }
            switch change {
            case .imported?: report.importedKeys.append(secret.identifier)
            case .removed?: report.removedKeys.append(secret.identifier)
            case nil: break
            }
        }
    }

    /// One import step, refused once a later change to key import begins when
    /// the import belongs to the change holding `revision`.
    private func updateKeys<Value>(
        _ revision: UInt64?,
        _ change: (inout DesktopCloudSyncState) throws -> Value
    ) async throws -> Value {
        guard let revision else { return try await state.update(change) }
        return try await state.update(forKeyImportRevision: revision, change)
    }
}
