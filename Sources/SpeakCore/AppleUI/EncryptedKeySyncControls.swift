import SwiftUI

/// What the encrypted API-key sync controls show about the sync engine.
public struct EncryptedKeySyncDisplayStatus: Equatable, Sendable {
    public var isEnabled: Bool
    public var isSyncing: Bool
    public var message: String

    public init(isEnabled: Bool, isSyncing: Bool, message: String) {
        self.isEnabled = isEnabled
        self.isSyncing = isSyncing
        self.message = message
    }
}

/// The status row, passphrase entry, sync and disable buttons, and error line
/// for encrypted CloudKit API-key sync, shared by the macOS settings card and
/// the iOS settings section. Each platform supplies its own chrome, footnote
/// and what to do after enabling or syncing (iOS reloads its synced keys).
public struct EncryptedKeySyncControls: View {
    private let status: EncryptedKeySyncDisplayStatus
    private let statusTitle: String
    private let statusSystemImage: String
    private let spacing: CGFloat
    private let enable: (String) async throws -> Void
    private let syncNow: () async throws -> Void
    private let disable: () async -> Void
    @State private var passphrase = ""
    @State private var syncError: String?

    public init(
        status: EncryptedKeySyncDisplayStatus,
        statusTitle: String,
        statusSystemImage: String,
        spacing: CGFloat,
        enable: @escaping (String) async throws -> Void,
        syncNow: @escaping () async throws -> Void,
        disable: @escaping () async -> Void
    ) {
        self.status = status
        self.statusTitle = statusTitle
        self.statusSystemImage = statusSystemImage
        self.spacing = spacing
        self.enable = enable
        self.syncNow = syncNow
        self.disable = disable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack {
                Label(statusTitle, systemImage: statusSystemImage)
                Spacer()
                Text(status.message)
                    .foregroundStyle(status.isEnabled ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            if status.isEnabled {
                HStack {
                    Button {
                        run { try await syncNow() }
                    } label: {
                        Label("Sync Keys Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(status.isSyncing)
                    .accessibilityIdentifier("keySyncNow")

                    Button("Disable", role: .destructive) {
                        Task {
                            await disable()
                            syncError = nil
                        }
                    }
                    .accessibilityIdentifier("keySyncDisable")
                }
            } else {
                passphraseEntry
            }

            if let syncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var passphraseEntry: some View {
        let field = SecureField("Sync passphrase", text: $passphrase)
            .textContentType(.password)
            .privacySensitive()
            .accessibilityIdentifier("keySyncPassphrase")
        let button = Button {
            let entered = passphrase
            run {
                try await enable(entered)
                passphrase = ""
            }
        } label: {
            Label("Enable API-Key Sync", systemImage: "lock.open")
        }
        .disabled(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("keySyncEnable")
        #if os(macOS)
        field.textFieldStyle(.roundedBorder)
        button.buttonStyle(.borderedProminent)
        #else
        field.autocorrectionDisabled()
        button
        #endif
    }

    /// Runs `action`, clearing the error on success and showing it on failure.
    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                syncError = nil
            } catch {
                syncError = error.localizedDescription
            }
        }
    }
}
