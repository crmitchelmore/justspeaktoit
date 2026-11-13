import CloudKit
import CryptoKit
import Foundation
import os.log

import SpeakCore

// MARK: - Account changes and the sync generation

extension CloudKitKeySync {
    func validateCurrentAccount() async throws {
        let fingerprint = Self.accountFingerprint(try await dependencies.accountRecordName())
        try await adoptLegacyContainerAccountIfNeeded(fingerprint: fingerprint)
        try await resetAccountBoundState(ifNeededFor: fingerprint)
    }

    nonisolated static func accountFingerprint(_ recordName: String) -> String {
        SHA256.hash(data: Data(recordName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func handleCloudKitAccountChange() async {
        let suspendedWork = suspendActiveWork()
        uploads.clearRetries()
        await lifecycleLock.acquire()
        symmetricKey = nil
        status.isEnabled = false
        status.isCloudAvailable = false
        await waitForSuspendedWork(suspendedWork, context: "Suspended key sync ended with error")
        lifecycleLock.release()
        _ = await isAvailable()
    }

    private func resetAccountBoundState(ifNeededFor fingerprint: String) async throws {
        await lifecycleLock.acquire()
        defer { lifecycleLock.release() }
        guard dependencies.defaults.string(forKey: Self.accountIdentifierKey) != fingerprint else {
            return
        }
        let suspendedWork = suspendActiveWork()
        uploads.clearRetries()
        await waitForSuspendedWork(suspendedWork, context: "Suspended key sync ended with error")
        transfer.pending.removeAll()
        uploads.clearRetries()
        dependencies.defaults.removeObject(forKey: Self.enabledKey)
        dependencies.defaults.removeObject(forKey: Self.syncTokenKey)
        dependencies.defaults.removeObject(forKey: KeySyncCloudOperations.zoneCreatedKey)
        dependencies.defaults.removeObject(forKey: KeySyncCloudOperations.subscriptionCreatedKey)
        try await transfer.localState.removeDerivedKey()
        for identifier in Self.syncableIdentifiers {
            try await transfer.localState.removeUpdatedAt(identifier: identifier)
        }
        symmetricKey = nil
        status.isEnabled = false
        status.isSyncing = false
        status.lastSyncTime = nil
        status.lastErrorDescription = nil
        dependencies.defaults.set(fingerprint, forKey: Self.accountIdentifierKey)
    }

    /// Invalidates the current generation and cancels the running sync and
    /// every upload, returning them so the caller can wait for them to stop.
    func suspendActiveWork() -> SuspendedWork {
        let suspendedWork = SuspendedWork(syncTask: activeSync?.task, uploadTasks: uploads.suspend())
        syncGeneration &+= 1
        suspendedWork.syncTask?.cancel()
        activeSync = nil
        status.isSyncing = false
        return suspendedWork
    }

    func waitForSuspendedWork(_ suspendedWork: SuspendedWork, context: String) async {
        if let syncTask = suspendedWork.syncTask {
            do {
                try await syncTask.value
            } catch is CancellationError {
                // Expected after invalidating the previous generation.
            } catch {
                log.warning("\(context, privacy: .public): \(error.localizedDescription)")
            }
        }
        for task in suspendedWork.uploadTasks {
            await task.value
        }
    }

    func ensureSyncIsActive(generation: UInt64) throws {
        try ensureGenerationIsCurrent(generation)
        guard dependencies.defaults.bool(forKey: Self.enabledKey),
              status.isEnabled else {
            throw CancellationError()
        }
    }

    func ensureGenerationIsCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == syncGeneration else {
            throw CancellationError()
        }
    }
}
