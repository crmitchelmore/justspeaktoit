import SpeakCore
import SpeakSync
import SwiftUI

/// Where API keys are kept: encrypted CloudKit sync in App Store builds.
struct CloudKitKeySyncSettingsCard: View {
  let secureStorage: SecureAppStorage
  @ObservedObject private var keySync = CloudKitKeySync.shared

  var body: some View {
    SettingsCard(title: "Encrypted API-Key Sync", systemImage: "lock.icloud", tint: .brandLagoon) {
      VStack(alignment: .leading, spacing: 12) {
        EncryptedKeySyncControls(
          status: EncryptedKeySyncDisplayStatus(
            isEnabled: keySync.status.isEnabled,
            isSyncing: keySync.status.isSyncing,
            message: keySync.status.message
          ),
          statusTitle: "Status",
          statusSystemImage: keySync.status.isEnabled ? "checkmark.seal.fill" : "lock.fill",
          spacing: 12,
          enable: { try await keySync.enable(passphrase: $0) },
          syncNow: { try await keySync.syncNow() },
          disable: { await keySync.disable() }
        )

        Text(
          "Opt in to sync API keys through your private CloudKit database. Keys are encrypted with "
            + "CryptoKit before upload. Sync is available when this app is signed into iCloud and "
            + "CloudKit is available."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .task {
      let coreStorage = await secureStorage.coreStorage()
      await keySync.configure(secureStorage: coreStorage)
      _ = await keySync.isAvailable()
    }
  }
}

/// Where API keys are kept: the local Keychain in direct-download builds.
struct LocalKeychainStorageCard: View {
  var body: some View {
    SettingsCard(title: "Local Keychain Storage", systemImage: "key.fill", tint: .brandLagoon) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Stored locally on this Mac", systemImage: "checkmark.seal.fill")
          .foregroundStyle(.green)
        Text(
          "API keys stay in the macOS Keychain for this direct-download build. "
            + "Encrypted CloudKit API-key sync is available only in App Store builds."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}
