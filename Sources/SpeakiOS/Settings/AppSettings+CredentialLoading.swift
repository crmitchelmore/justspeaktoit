#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import UIKit

/// Loading API keys from the canonical Keychain store: the launch bootstrap,
/// retries when protected data becomes available, reloads after another
/// process or CloudKit sync changes a key, and default-provider selection.
extension AppSettings {
    /// Coalesces bootstrap and recording callers; a failed read remains retryable.
    /// Never use placeholder empty keys to make persistent provider decisions.
    @discardableResult
    public func ensureKeysLoaded() async -> Bool {
        if let keyLoadTask = secrets.loadTask { return await keyLoadTask.value }
        if credentialsAvailable { return true }
        let task = Task { @MainActor in
            guard await self.secrets.storage.preloadAndReportSuccess() else { return false }
            if self.secrets.migratesLegacyCredentials { await Self.migrateLegacyKeysIfNeeded() }
            guard await self.reloadSyncedAPIKeys() else { return false }
            self.configureDefaultProviderIfNeeded()
            return true
        }
        secrets.loadTask = task
        let success = await task.value
        secrets.loadTask = nil
        return success
    }

    /// Waits until every queued API-key write has finished.
    func awaitPendingSecretWrites() async {
        await secrets.awaitPendingWrites()
    }

    @discardableResult
    public func syncCloudKitKeys() async -> Bool {
        let keySync = CloudKitKeySync.shared
        await keySync.configure(secureStorage: Self.canonicalCredentialStorage)
        guard await keySync.isAvailable() else { return false }

        do {
            try await keySync.syncNow()
            await reloadSyncedAPIKeys()
            return true
        } catch {
            SpeakLogger.logger(category: "AppSettings")
                .error("CloudKit API-key sync failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Load all API keys from the canonical secure storage, migrating any
    /// values from legacy iOS keychain locations first. Default-provider
    /// selection runs afterwards so it sees the loaded keys.
    func startLoadingCredentials() {
        observeSecureStorageChanges()
        observeKeyboardProfileAvailability()
        secrets.protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.ensureKeysLoaded()
            }
        }
        Task { @MainActor [weak self] in
            await self?.ensureKeysLoaded()
        }
    }

    private func observeSecureStorageChanges() {
        guard secrets.keyChangeObserver == nil else { return }
        secrets.keyChangeObserver = NotificationCenter.default.addObserver(
            forName: SecureStorage.didChangeSecretNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let identifier = notification.userInfo?[SecureStorage.NotificationUserInfoKey.identifier] as? String,
                  CloudKitKeySync.syncableIdentifiers.contains(identifier) else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.reloadSyncedAPIKeys()
            }
        }
    }

    /// Configure default transcription provider based on available API keys.
    /// Prefers Deepgram if API key is available, otherwise falls back to Apple Speech.
    private func configureDefaultProviderIfNeeded() {
        let isFirstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore.rawValue)
        let needsDeepgramKey = selectedModel.hasPrefix("deepgram") && !hasDeepgramKey

        // Note: ElevenLabs key is loaded async; its fallback is handled at recording time.
        if isFirstLaunch || needsDeepgramKey {
            if hasDeepgramKey {
                selectedModel = "deepgram/nova-3-streaming"
            } else {
                selectedModel = AppleLocalModels.preferredSpeechModelID
            }
            defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore.rawValue)
        }
    }
}
#endif
