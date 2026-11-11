import SpeakCore
import SpeakSync
import SwiftUI

/// Where API keys are kept: encrypted CloudKit sync in App Store builds.
struct CloudKitKeySyncSettingsCard: View {
  let secureStorage: SecureAppStorage
  @ObservedObject private var keySync = CloudKitKeySync.shared
  @State private var passphrase = ""
  @State private var syncError: String?

  var body: some View {
    SettingsCard(title: "Encrypted API-Key Sync", systemImage: "lock.icloud", tint: .brandLagoon) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("Status", systemImage: keySync.status.isEnabled ? "checkmark.seal.fill" : "lock.fill")
          Spacer()
          Text(keySync.status.message)
            .foregroundStyle(keySync.status.isEnabled ? .green : .secondary)
        }

        if !keySync.status.isEnabled {
          SecureField("Sync passphrase", text: $passphrase)
            .textContentType(.password)
            .privacySensitive()
            .textFieldStyle(.roundedBorder)

          Button {
            Task {
              do {
                try await keySync.enable(passphrase: passphrase)
                passphrase = ""
                syncError = nil
              } catch {
                syncError = error.localizedDescription
              }
            }
          } label: {
            Label("Enable API-Key Sync", systemImage: "lock.open")
          }
          .disabled(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .buttonStyle(.borderedProminent)
        } else {
          HStack {
            Button {
              Task {
                do {
                  try await keySync.syncNow()
                  syncError = nil
                } catch {
                  syncError = error.localizedDescription
                }
              }
            } label: {
              Label("Sync Keys Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(keySync.status.isSyncing)

            Button("Disable", role: .destructive) {
              Task { await keySync.disable() }
            }
          }
        }

        if let syncError {
          Text(syncError)
            .font(.caption)
            .foregroundStyle(.red)
        }

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
