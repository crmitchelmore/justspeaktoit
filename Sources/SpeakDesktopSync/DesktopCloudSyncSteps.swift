import Foundation
import SpeakSync

/// A History pass on this device goes on only while its web session is the
/// one the account was validated in and History sync is still turned on.
/// Each step holds the session for its whole duration. Turning History off is
/// noticed when the next step or request begins, so at most the step already
/// under way completes.
final class DesktopHistoryPassFence: HistorySyncPassFence {
    private let session: CloudKitWebSessionFence
    private let state: DesktopCloudSyncStateStore

    init(session: CloudKitWebSessionFence, state: DesktopCloudSyncStateStore) {
        self.session = session
        self.state = state
    }

    func admit<Value>(
        isolation: isolated (any Actor)?,
        _ work: () async throws -> Value
    ) async throws -> Value {
        try await session.admit(isolation: isolation) {
            guard await state.current.enabledFeatures.contains(.history) else {
                throw CloudKitWebServicesError.consentRequired(.history)
            }
            return try await work()
        }
    }
}

/// The account-bound steps of API-key import. Run each inside one update of
/// the sync state, admitted by the pass's session fence: it is then decided
/// against the bookkeeping as it is at that moment, cannot interleave with
/// turning import off or with a key saved by hand, and is never half applied.
/// Key values pass only between the call and the credential vault; nothing
/// here logs, reports or stores them anywhere else.
enum DesktopKeyImport {
    enum Change: Equatable, Sendable {
        case imported
        case removed
    }

    /// Stores the key-sync key derived from the passphrase and turns import on.
    static func store(_ key: Data, in state: inout DesktopCloudSyncState, vault: any DesktopCredentialVault) throws {
        try vault.writeCredential(key.base64EncodedString(), name: DesktopCloudSyncCredential.apiKeySyncKey)
        state.enabledFeatures.insert(.apiKeys)
    }

    /// Applies one synced key if it is newer than what this device has
    /// considered. A newer value is saved as imported; a newer deletion
    /// removes the saved value only while it is still the imported one, never
    /// a key saved by hand.
    static func apply(
        _ secret: CloudKitWebSyncedSecret,
        to state: inout DesktopCloudSyncState,
        vault: any DesktopCredentialVault
    ) throws -> Change? {
        try requireImport(state)
        let known = state.importedKeys[secret.identifier]
        if let known, known.lastRemoteUpdate >= secret.updatedAt { return nil }
        var change: Change?
        if let value = secret.value {
            try vault.writeCredential(value, name: secret.identifier)
            change = .imported
        } else if known?.isImportedValue == true {
            try vault.deleteCredential(secret.identifier)
            change = .removed
        }
        state.importedKeys[secret.identifier] = DesktopCloudSyncState.ImportedKey(
            lastRemoteUpdate: secret.updatedAt,
            isImportedValue: secret.value != nil
        )
        return change
    }

    /// Forgets a key-sync key the account no longer accepts and turns import
    /// off, so the user is asked for the passphrase again, unless another key
    /// was stored after `encoded` was read. Returns whether it did.
    static func forget(
        _ encoded: String,
        in state: inout DesktopCloudSyncState,
        vault: any DesktopCredentialVault
    ) throws -> Bool {
        try requireImport(state)
        guard try vault.readCredential(DesktopCloudSyncCredential.apiKeySyncKey) == encoded else { return false }
        try? vault.deleteCredential(DesktopCloudSyncCredential.apiKeySyncKey)
        state.enabledFeatures.remove(.apiKeys)
        return true
    }

    /// Saves a key typed on this device, or removes it when `value` is empty,
    /// and marks it saved by hand, so a later remote deletion leaves it alone.
    static func saveByHand(
        _ value: String,
        identifier: String,
        in state: inout DesktopCloudSyncState,
        vault: any DesktopCredentialVault
    ) throws {
        if value.isEmpty {
            try vault.deleteCredential(identifier)
        } else {
            try vault.writeCredential(value, name: identifier)
        }
        state.importedKeys[identifier]?.isImportedValue = false
    }

    /// Import stops as soon as it is turned off.
    private static func requireImport(_ state: DesktopCloudSyncState) throws {
        guard state.enabledFeatures.contains(.apiKeys) else {
            throw CloudKitWebServicesError.consentRequired(.apiKeys)
        }
    }
}
