#if os(iOS)
import SpeakCore
import SpeakSync
import SwiftUI

// MARK: - CloudKit Sync Settings

struct CloudKitSyncSettingsSection: View {
    @ObservedObject private var syncEngine = HistorySyncEngine.shared
    @StateObject private var historyManager = iOSHistoryManager.shared
    @State private var isSyncing = false

    var body: some View {
        let availability = SyncAvailability.current(iCloudCloudKitAvailable: syncEngine.state.isCloudAvailable)

        // CloudKit status
        HStack {
            Label("iCloud History Sync", systemImage: "icloud")
            Spacer()
            Text(availability.iCloudCloudKitAvailable ? "Active" : "Unavailable")
                .foregroundStyle(
                    availability.iCloudCloudKitAvailable ? .green : .secondary
                )
        }
        .accessibilityElement(children: .combine)

        if availability.iCloudCloudKitAvailable {
            // Sync counts
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Synced Entries")
                        .font(.subheadline)
                    Text("\(historyManager.syncedCount) of \(historyManager.items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if historyManager.unsyncedCount > 0 {
                    Text("\(historyManager.unsyncedCount) pending")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color.orange.opacity(0.12),
                            in: Capsule()
                        )
                } else if !historyManager.items.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            // Last sync time
            if let lastSync = syncEngine.state.lastSyncTime {
                LabeledContent("Last Sync") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            // Error display
            if let error = syncEngine.state.error {
                Label {
                    Text(error.localizedDescription)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }

            // Manual sync button
            Button {
                isSyncing = true
                Task {
                    await historyManager.triggerSync()
                    isSyncing = false
                }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncing || syncEngine.state.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isSyncing || syncEngine.state.isSyncing)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    availability.transportAvailable
                        ? "Sign in to iCloud to sync history automatically. Until then, Bonjour Transport "
                            + "can send new sessions to a paired Mac on your local network."
                        : "Sign in to iCloud in Settings to sync transcription history across your devices."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CloudKitKeySyncSettingsSection: View {
    @ObservedObject private var keySync = CloudKitKeySync.shared
    @State private var passphrase = ""
    @State private var syncError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Encrypted API-Key Sync", systemImage: "lock.icloud")
                Spacer()
                Text(keySync.status.message)
                    .foregroundStyle(keySync.status.isEnabled ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            if !keySync.status.isEnabled {
                SecureField("Sync passphrase", text: $passphrase)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .privacySensitive()

                Button {
                    Task {
                        do {
                            try await keySync.enable(passphrase: passphrase)
                            await AppSettings.shared.reloadSyncedAPIKeys()
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
            } else {
                HStack {
                    Button {
                        Task {
                            do {
                                try await keySync.syncNow()
                                await AppSettings.shared.reloadSyncedAPIKeys()
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

            Text("Keys are encrypted on this device before they are written to your private CloudKit database.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            _ = await AppSettings.shared.syncCloudKitKeys()
        }
    }
}

#endif
