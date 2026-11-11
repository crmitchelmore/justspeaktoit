import Foundation
import SwiftUI

/// Holds the balance shown beside each saved API key.
///
/// Three rules shape this type. Balances are keyed by *account*, so an account
/// whose one key serves both transcription and voice output is fetched once and
/// displayed once. Nothing here can fail loudly: every fetch resolves to a
/// state, so a billing endpoint that is down leaves the settings screen and
/// every transcription path untouched. And no state is ever inferred from a
/// stored key — a saved credential produces a request, never an assumption
/// about what the account holds.
@MainActor
public final class ProviderBalanceStore: ObservableObject {
    public enum Entry: Equatable {
        case idle
        case refreshing
        case loaded(ProviderBalanceSnapshot)
    }

    @Published public private(set) var entries: [String: Entry] = [:]

    private let sources: [String: any ProviderBalanceSource]
    private var credentialProvider: (@Sendable (String) async -> String?)?
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Bumped whenever an account's credential changes or a refresh is
    /// superseded, so a result from an older request cannot repopulate the
    /// entry with a figure that belongs to a key the user has replaced.
    private var generations: [String: Int] = [:]

    /// - Parameters:
    ///   - session: Session used for every billing request.
    ///   - sources: Overrides the default transports; tests inject stubs here.
    public init(
        session: URLSession = .shared,
        sources: [any ProviderBalanceSource]? = nil
    ) {
        let resolved = sources ?? Self.defaultSources(session: session)
        // A duplicate `accountID` is a caller mistake, not a reason to
        // terminate the process from a public initializer: the first source
        // for an account wins and the rest are ignored.
        self.sources = resolved.reduce(into: [:]) { table, source in
            if table[source.accountID] == nil { table[source.accountID] = source }
        }
    }

    /// Only providers with a documented balance contract get a transport.
    /// Everything else is a billing link, decided by `ProviderBalanceDirectory`.
    public static func defaultSources(session: URLSession = .shared) -> [any ProviderBalanceSource] {
        [
            DeepgramBalanceClient(session: session),
            RevAIBalanceClient(session: session),
            ElevenLabsBalanceClient(session: session),
            OpenRouterBalanceClient(session: session)
        ]
    }

    /// Supplies the credential reader. Kept separate from `init` so the store
    /// can be a `@StateObject` while the Keychain it reads arrives from the
    /// view environment.
    public func configure(credentialProvider: @escaping @Sendable (String) async -> String?) {
        self.credentialProvider = credentialProvider
    }

    /// The entry to render beside a given API-key card, or `nil` when this card
    /// is not the account's primary credential — that is the deduplication.
    public func entry(forCredentialIdentifier identifier: String) -> Entry? {
        guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier),
              account.primaryCredentialIdentifier == identifier,
              account.support == .balance
        else { return nil }
        return entries[account.id] ?? .idle
    }

    /// Refreshes one account. A refresh already in flight is cancelled first so
    /// a rapid second tap cannot land an older figure on top of a newer one.
    public func refresh(accountID: String) {
        guard let source = sources[accountID], let credentialProvider else { return }
        guard let account = ProviderBalanceDirectory.account(id: accountID) else { return }

        refreshTasks[accountID]?.cancel()
        entries[accountID] = .refreshing
        let generation = nextGeneration(for: accountID)

        let identifier = account.primaryCredentialIdentifier
        let displayName = account.displayName
        refreshTasks[accountID] = Task { [weak self] in
            let key = await credentialProvider(identifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled else { return }

            guard let key, !key.isEmpty else {
                self?.store(
                    ProviderBalanceSnapshot(
                        accountID: accountID,
                        providerDisplayName: displayName,
                        state: .unknown(reason: "Save a key to check this account's balance."),
                        refreshedAt: Date()
                    ),
                    for: accountID,
                    generation: generation
                )
                return
            }

            let snapshot = await source.fetchBalance(apiKey: key)
            guard !Task.isCancelled else { return }
            self?.store(snapshot, for: accountID, generation: generation)
        }
    }

    /// Refreshes every supported account whose credential is actually stored.
    /// Accounts without a saved key are left alone rather than probed.
    public func refreshAll(storedCredentialIdentifiers: Set<String>) {
        for account in ProviderBalanceDirectory.accounts
        where account.support == .balance
            && storedCredentialIdentifiers.contains(account.primaryCredentialIdentifier) {
            refresh(accountID: account.id)
        }
    }

    /// Forgets an account's figure and drops any request still in flight for
    /// it, so a replaced or cleared credential cannot leave the previous
    /// account's balance on screen and an older request cannot land on top of
    /// the new one.
    public func invalidate(accountID: String) {
        refreshTasks[accountID]?.cancel()
        refreshTasks[accountID] = nil
        _ = nextGeneration(for: accountID)
        entries[accountID] = .idle
    }

    /// Invalidates the account a credential belongs to. Nothing happens when
    /// the identifier belongs to no known account.
    public func invalidate(credentialIdentifier: String) {
        guard let account = ProviderBalanceDirectory.account(
            forCredentialIdentifier: credentialIdentifier
        ) else { return }
        invalidate(accountID: account.id)
    }

    /// Invalidates every account, then re-reads the ones whose key is stored.
    /// Called after any credential mutation, so nothing on screen can belong
    /// to a key that is no longer saved.
    public func reloadAfterCredentialChange(storedCredentialIdentifiers: Set<String>) {
        for account in ProviderBalanceDirectory.accounts {
            invalidate(accountID: account.id)
        }
        refreshAll(storedCredentialIdentifiers: storedCredentialIdentifiers)
    }

    /// Drops in-flight work, for example when the settings screen goes away.
    public func cancelAll() {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        for (accountID, entry) in entries where entry == .refreshing {
            entries[accountID] = .idle
        }
    }

    private func nextGeneration(for accountID: String) -> Int {
        let generation = (generations[accountID] ?? 0) + 1
        generations[accountID] = generation
        return generation
    }

    private func store(
        _ snapshot: ProviderBalanceSnapshot,
        for accountID: String,
        generation: Int
    ) {
        // A result from a superseded request describes a credential the user
        // has since replaced, so it is dropped rather than rendered.
        guard generations[accountID] == generation else { return }
        entries[accountID] = .loaded(snapshot)
        refreshTasks[accountID] = nil
    }
}

// MARK: - Shared presentation

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
