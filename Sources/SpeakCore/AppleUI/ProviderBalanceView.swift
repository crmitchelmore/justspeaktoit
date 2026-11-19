import Foundation
import SwiftUI

/// The balance block shown inside an API-key card on both platforms.
///
/// Renders the account's figure when one has been fetched, a billing link when
/// the provider has no readable balance, and nothing at all until a key is
/// saved — presence of a key is never itself reported as entitlement.
public struct ProviderBalanceView: View {
    private let credentialIdentifier: String
    private let isKeyStored: Bool
    private let presentsAccountBalance: Bool
    @ObservedObject private var store: ProviderBalanceStore

    /// - Parameters:
    ///   - credentialIdentifier: The Keychain item this card edits.
    ///   - isKeyStored: Whether that item currently holds a key.
    ///   - presentsAccountBalance: Whether this card is the one that shows the
    ///     account's figure. Two cards can edit the same Keychain item —
    ///     Deepgram has a transcription card and a voice-output card, both on
    ///     `deepgram.apiKey` — and the identifier alone cannot tell them
    ///     apart, so the card that does not own the account passes `false` and
    ///     the balance is still shown exactly once.
    ///   - store: The balance store to read.
    public init(
        credentialIdentifier: String,
        isKeyStored: Bool,
        presentsAccountBalance: Bool = true,
        store: ProviderBalanceStore
    ) {
        self.credentialIdentifier = credentialIdentifier
        self.isKeyStored = isKeyStored
        self.presentsAccountBalance = presentsAccountBalance
        self.store = store
    }

    private var account: ProviderBalanceAccount? {
        ProviderBalanceDirectory.account(forCredentialIdentifier: credentialIdentifier)
    }

    public var body: some View {
        if presentsAccountBalance,
           let account,
           account.primaryCredentialIdentifier == credentialIdentifier {
            VStack(alignment: .leading, spacing: 4) {
                switch account.support {
                case .balance:
                    balanceContent(for: account)
                case .billingLinkOnly(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let billingURL = account.billingURL {
                    Link(destination: billingURL) {
                        Label("Open billing", systemImage: "creditcard")
                            .font(.caption)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func balanceContent(for account: ProviderBalanceAccount) -> some View {
        if !isKeyStored {
            Text("Save a \(account.displayName) key to see the account balance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch store.entry(forCredentialIdentifier: credentialIdentifier) ?? .idle {
            case .idle:
                Button {
                    store.refresh(accountID: account.id)
                } label: {
                    Label("Check balance", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            case .refreshing:
                Text("Checking balance…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let snapshot):
                loadedBalance(snapshot, account: account)
            }
        }
    }

    @ViewBuilder
    private func loadedBalance(_ snapshot: ProviderBalanceSnapshot, account: ProviderBalanceAccount) -> some View {
        Label(
            ProviderBalanceFormatter.summary(for: snapshot.state),
            systemImage: snapshot.state.isSpendableCredit ? "creditcard.fill" : "questionmark.circle"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(snapshot.state.isSpendableCredit ? Color.primary : Color.secondary)

        if let detail = ProviderBalanceFormatter.detail(for: snapshot.state) {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if let schedule = ProviderBalanceFormatter.scheduleDescription(for: snapshot) {
            Text(schedule)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
            Text(ProviderBalanceFormatter.refreshDescription(for: snapshot))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                store.refresh(accountID: account.id)
            } label: {
                Label("Refresh balance", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh \(account.displayName) balance")
        }
    }
}
