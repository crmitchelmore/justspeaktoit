import Foundation
import SpeakCore

/// The balance text the API Keys page shows beside one provider's key.
///
/// `identifier` is the account's primary credential row; no other row of the
/// same account shows a line, so one account is shown once. The text never
/// contains key material: it is built from the shared directory and the
/// snapshot the provider returned.
package struct DesktopProviderBalanceLine: Equatable, Sendable {
    package let identifier: String
    package let text: String
    /// The page offers Check balance for this row.
    package let canRefresh: Bool
    /// The line holds a result worth announcing, not a placeholder.
    package let isResult: Bool
}

/// Windows and Linux balances beside API keys, matching `ProviderBalanceStore`
/// on macOS and iOS: keyed by account, fetched only for a saved key, never
/// throwing, and never on a key-entry or transcription path. Balances travel
/// to the native page on their own channel, so a slow billing endpoint cannot
/// hold a Save, Remove or Check validity.
package actor DesktopProviderBalances {
    package typealias KeyReader = @Sendable (String) async -> String?
    package typealias Publisher = @Sendable (DesktopProviderBalanceLine) -> Void

    private enum Entry: Equatable {
        case idle
        case refreshing
        case loaded(ProviderBalanceSnapshot)
    }

    private let sources: [String: any ProviderBalanceSource]
    private let now: @Sendable () -> Date
    private let readKey: KeyReader
    private let publish: Publisher
    private var entries: [String: Entry] = [:]
    /// Primary credential identifiers the latest rows reported as saved.
    private var saved: Set<String> = []
    private var shown: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Bumped on every refresh or credential change so a superseded result
    /// cannot land on a key the user has since replaced or removed.
    private var generations: [String: Int] = [:]

    /// - Parameters:
    ///   - readKey: Reads a saved key off the UI thread; nil when none is saved.
    ///   - publish: Hands one line to the native page; called on this actor.
    package init(
        sources: [any ProviderBalanceSource] = ProviderBalanceSources.defaults(),
        now: @escaping @Sendable () -> Date = { Date() },
        readKey: @escaping KeyReader,
        publish: @escaping Publisher
    ) {
        self.sources = sources.reduce(into: [:]) { table, source in
            if table[source.accountID] == nil { table[source.accountID] = source }
        }
        self.now = now
        self.readKey = readKey
        self.publish = publish
    }

    /// Takes the rows the page now shows and publishes every primary row's
    /// line. A key that is no longer saved drops its figure at once.
    package func show(_ rows: [DesktopAPIKeyRow]) {
        shown = Set(rows.map(\.identifier))
        let nowSaved = Set(rows.filter(\.isSaved).map(\.identifier))
        for identifier in saved.subtracting(nowSaved) {
            guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier) else { continue }
            cancel(account.id)
            entries[account.id] = .idle
        }
        saved = nowSaved
        for account in ProviderBalanceDirectory.accounts where shown.contains(account.primaryCredentialIdentifier) {
            emit(account)
        }
    }

    /// Refreshes every readable account whose key is saved, as the Apple
    /// pages do when they open.
    package func refreshSaved() {
        for account in ProviderBalanceDirectory.accounts
        where account.support == .balance && saved.contains(account.primaryCredentialIdentifier) {
            refresh(account)
        }
    }

    /// Check balance on one row. A row with no readable account or no saved
    /// key gets its current line again, so the page never waits on nothing.
    package func refresh(credentialIdentifier identifier: String) {
        guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier) else { return }
        guard account.support == .balance, saved.contains(account.primaryCredentialIdentifier) else {
            if shown.contains(account.primaryCredentialIdentifier) { emit(account) }
            return
        }
        refresh(account)
    }

    /// A key was saved, replaced or removed: forget the account's figure and
    /// drop any request for the previous key.
    package func credentialChanged(_ identifier: String) {
        guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier) else { return }
        cancel(account.id)
        entries[account.id] = .idle
        if shown.contains(account.primaryCredentialIdentifier) { emit(account) }
    }

    /// The line for one account's primary row, from its current state.
    package func line(forCredentialIdentifier identifier: String) -> DesktopProviderBalanceLine? {
        guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier),
              account.primaryCredentialIdentifier == identifier else { return nil }
        return Self.line(
            for: account, entry: entries[account.id] ?? .idle,
            isSaved: saved.contains(identifier), hasSource: sources[account.id] != nil, now: now()
        )
    }

    private func refresh(_ account: ProviderBalanceAccount) {
        guard let source = sources[account.id] else { return }
        cancel(account.id)
        let generation = (generations[account.id] ?? 0) + 1
        generations[account.id] = generation
        entries[account.id] = .refreshing
        emit(account)
        let identifier = account.primaryCredentialIdentifier
        let displayName = account.displayName
        let now = now, readKey = readKey
        tasks[account.id] = Task { [weak self] in
            let key = await readKey(identifier)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled else { return }
            let snapshot: ProviderBalanceSnapshot
            if let key, !key.isEmpty {
                snapshot = await source.fetchBalance(apiKey: key)
            } else {
                snapshot = ProviderBalanceSnapshot(
                    accountID: account.id, providerDisplayName: displayName,
                    state: .unknown(reason: "Save a key to check this account's balance."), refreshedAt: now()
                )
            }
            guard !Task.isCancelled else { return }
            await self?.store(snapshot, account: account, generation: generation)
        }
    }

    private func store(_ snapshot: ProviderBalanceSnapshot, account: ProviderBalanceAccount, generation: Int) {
        guard generations[account.id] == generation else { return }
        tasks[account.id] = nil
        entries[account.id] = .loaded(snapshot)
        emit(account)
    }

    private func cancel(_ accountID: String) {
        tasks[accountID]?.cancel()
        tasks[accountID] = nil
        generations[accountID] = (generations[accountID] ?? 0) + 1
    }

    private func emit(_ account: ProviderBalanceAccount) {
        guard let line = line(forCredentialIdentifier: account.primaryCredentialIdentifier) else { return }
        publish(line)
    }

    private static func line(
        for account: ProviderBalanceAccount, entry: Entry, isSaved: Bool, hasSource: Bool, now: Date
    ) -> DesktopProviderBalanceLine {
        let identifier = account.primaryCredentialIdentifier
        func line(_ text: String, refresh: Bool = false, result: Bool = false) -> DesktopProviderBalanceLine {
            DesktopProviderBalanceLine(identifier: identifier, text: text, canRefresh: refresh, isResult: result)
        }
        guard case .balance = account.support, hasSource else {
            var text = "Balance: not shown here."
            if case .billingLinkOnly(let reason) = account.support { text += " \(reason)" }
            if let url = account.billingURL { text += " Billing: \(url.absoluteString)" }
            return line(text)
        }
        guard isSaved else { return line("Balance: save a \(account.displayName) key to see the account balance.") }
        switch entry {
        case .idle:
            return line("Balance: not checked yet. Choose Check balance.", refresh: true)
        case .refreshing:
            // Still pressable: a second press restarts the check, as on the Mac,
            // and the focused button never disappears from under the keyboard.
            return line("Balance: checking…", refresh: true)
        case .loaded(let snapshot):
            return line(text(for: snapshot, now: now), refresh: true, result: true)
        }
    }

    /// One line in the order the Apple view stacks it: figure, explanation,
    /// reset or expiry, then when it was checked.
    package static func text(for snapshot: ProviderBalanceSnapshot, now: Date = Date()) -> String {
        let summary = ProviderBalanceFormatter.summary(for: snapshot.state)
        var parts = [summary.hasPrefix("Balance") ? "\(summary)." : "Balance: \(summary)."]
        if let detail = ProviderBalanceFormatter.detail(for: snapshot.state) { parts.append(sentence(detail)) }
        if let schedule = ProviderBalanceFormatter.scheduleDescription(for: snapshot) {
            parts.append(sentence(schedule))
        }
        parts.append(sentence(ProviderBalanceFormatter.refreshDescription(for: snapshot, now: now)))
        return parts.joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}

extension DesktopHostController {
    /// The saved key for a balance check, read off the actor like every other
    /// secure-storage read. Nil when nothing is saved or the store failed, so
    /// a balance never reports why a credential store could not be read.
    package func savedAPIKeyForBalance(identifier: String) async -> String? {
        guard !closed else { return nil }
        let effects = effects
        let key = try? await Task.detached { try effects.apiKey(name: identifier) }.value
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }
}
