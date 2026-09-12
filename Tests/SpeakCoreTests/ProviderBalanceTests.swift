import Foundation
import XCTest

@testable import SpeakCore

/// The balance model, the account directory and the store that drives the
/// settings surface.
final class ProviderBalanceTests: XCTestCase {
    // MARK: - Formatting

    func testFormatter_neverRendersAMissingLimitAsUnlimited() {
        let state = ProviderBalanceState.allowance(remaining: 500, total: nil, unit: .characters)

        XCTAssertEqual(ProviderBalanceFormatter.summary(for: state), "500 characters left (limit unknown)")
        XCTAssertEqual(
            ProviderBalanceFormatter.detail(for: state),
            "The provider did not report a limit, so the total is unknown."
        )
    }

    func testFormatter_rendersUsageAsUsageNotAsABalance() {
        let state = ProviderBalanceState.usage(
            spent: ProviderBalanceMoney(amount: Decimal(3), currencyCode: "USD"),
            quantity: nil,
            unit: nil,
            note: "Admin cost report, not a wallet balance."
        )

        XCTAssertEqual(ProviderBalanceFormatter.summary(for: state), "$3.00 used")
        XCTAssertFalse(state.isSpendableCredit)
    }

    func testFormatter_rendersCashWithTheReportedCurrency() {
        XCTAssertEqual(
            ProviderBalanceFormatter.summary(
                for: .cash(ProviderBalanceMoney(amount: Decimal(4.1), currencyCode: "usd"))
            ),
            "$4.10 credit"
        )
        XCTAssertEqual(
            ProviderBalanceFormatter.summary(
                for: .cash(ProviderBalanceMoney(amount: Decimal(4.1), currencyCode: "SEK"))
            ),
            "4.10 SEK credit"
        )
    }

    func testFormatter_describesResetAndExpiryDates() {
        let snapshot = ProviderBalanceSnapshot(
            accountID: "elevenlabs",
            providerDisplayName: "ElevenLabs",
            state: .allowance(remaining: 1, total: 2, unit: .characters),
            refreshedAt: Date(timeIntervalSince1970: 0),
            resetsAt: Date(timeIntervalSince1970: 1_790_000_000)
        )

        XCTAssertTrue(
            ProviderBalanceFormatter.scheduleDescription(for: snapshot)?.hasPrefix("Resets ") == true
        )
    }

    // MARK: - Directory

    func testDirectory_coversEveryCredentialTheCataloguesCanRequire() {
        for identifier in ModelCredentialResolver.allKnownAPIKeyIdentifiers {
            XCTAssertNotNil(
                ProviderBalanceDirectory.account(forCredentialIdentifier: identifier),
                "No balance account or billing link is defined for \(identifier)"
            )
        }
    }

    func testDirectory_supportsOnlyTheDocumentedBalanceProviders() {
        let supported = ProviderBalanceDirectory.accounts
            .filter { $0.support == .balance }
            .map(\.id)
            .sorted()

        XCTAssertEqual(supported, ["deepgram", "elevenlabs", "openrouter", "revai"])
    }

    func testDirectory_neverLabelsUsageOnlyProvidersAsAWallet() {
        for id in ["cartesia", "soniox", "openai", "azure"] {
            guard let account = ProviderBalanceDirectory.account(id: id) else {
                return XCTFail("Missing account \(id)")
            }
            guard case .billingLinkOnly = account.support else {
                return XCTFail("\(id) must be a billing link, not a wallet balance")
            }
            XCTAssertNotNil(account.billingURL, "\(id) needs a billing link")
        }
    }

    func testDirectory_deduplicatesAnAccountAcrossItsCredentials() {
        XCTAssertTrue(ProviderBalanceDirectory.isPrimaryCredential("openai.apiKey"))
        XCTAssertFalse(ProviderBalanceDirectory.isPrimaryCredential("openai.tts.apiKey"))
        XCTAssertEqual(
            ProviderBalanceDirectory.account(forCredentialIdentifier: "openai.tts.apiKey")?.id,
            ProviderBalanceDirectory.account(forCredentialIdentifier: "openai.apiKey")?.id
        )
    }

    func testDirectory_givesEveryAccountABillingLink() {
        for account in ProviderBalanceDirectory.accounts {
            XCTAssertNotNil(account.billingURL, "\(account.id) has no billing link")
        }
    }

    // MARK: - Store

    @MainActor
    func testStore_showsAnAccountOnceAcrossItsSpeechAndVoiceCredentials() async {
        let store = ProviderBalanceStore(sources: [StubBalanceSource(accountID: "openai")])

        XCTAssertNil(store.entry(forCredentialIdentifier: "openai.tts.apiKey"))
        // OpenAI is billing-link only, so even its primary card shows no figure.
        XCTAssertNil(store.entry(forCredentialIdentifier: "openai.apiKey"))
        XCTAssertEqual(store.entry(forCredentialIdentifier: "deepgram.apiKey"), .idle)
    }

    @MainActor
    func testStore_refreshOnlyTouchesAccountsWithASavedKey() async {
        let source = StubBalanceSource(accountID: "deepgram")
        let store = ProviderBalanceStore(sources: [source])
        store.configure { _ in "dg-key" }

        store.refreshAll(storedCredentialIdentifiers: [])
        XCTAssertEqual(store.entries["deepgram"] ?? .idle, .idle)

        store.refreshAll(storedCredentialIdentifiers: ["deepgram.apiKey"])
        await store.waitForIdle()
        guard case .loaded(let snapshot) = store.entries["deepgram"] else {
            return XCTFail("Expected a loaded balance, got \(String(describing: store.entries["deepgram"]))")
        }
        XCTAssertEqual(snapshot.state, .cash(ProviderBalanceMoney(amount: 1, currencyCode: "USD")))
    }

    @MainActor
    func testStore_reportsUnknownRatherThanCreditWhenNoKeyIsStored() async {
        let store = ProviderBalanceStore(sources: [StubBalanceSource(accountID: "deepgram")])
        store.configure { _ in nil }

        store.refresh(accountID: "deepgram")
        await store.waitForIdle()

        guard case .loaded(let snapshot) = store.entries["deepgram"] else {
            return XCTFail("Expected a loaded entry, got \(String(describing: store.entries["deepgram"]))")
        }
        XCTAssertFalse(snapshot.state.isSpendableCredit)
    }

    /// A replaced key must not leave the previous account's figure rendered.
    @MainActor
    func testStore_forgetsALoadedBalanceWhenItsCredentialChanges() async {
        let store = ProviderBalanceStore(sources: [StubBalanceSource(accountID: "deepgram")])
        store.configure { _ in "dg-key" }
        store.refresh(accountID: "deepgram")
        await store.waitForIdle()
        guard case .loaded = store.entries["deepgram"] else {
            return XCTFail("Expected a loaded balance before the credential changes")
        }

        store.invalidate(credentialIdentifier: "deepgram.apiKey")
        XCTAssertEqual(store.entries["deepgram"], .idle)
        XCTAssertEqual(store.entry(forCredentialIdentifier: "deepgram.apiKey"), .idle)
    }

    /// A result from the request that was in flight when the key changed
    /// describes the previous account, so it must not repopulate the entry.
    @MainActor
    func testStore_dropsAResultFromASupersededRequest() async {
        let source = SlowBalanceSource(accountID: "deepgram")
        let store = ProviderBalanceStore(sources: [source])
        store.configure { _ in "dg-key" }

        store.refresh(accountID: "deepgram")
        XCTAssertEqual(store.entries["deepgram"], .refreshing)
        store.invalidate(accountID: "deepgram")
        source.release()

        // Give the superseded task every chance to publish.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            store.entries["deepgram"], .idle,
            "a superseded request must not repopulate the entry"
        )
    }

    @MainActor
    func testStore_ignoresADuplicateInjectedSourceRatherThanTrapping() {
        let store = ProviderBalanceStore(sources: [
            StubBalanceSource(accountID: "deepgram"),
            StubBalanceSource(accountID: "deepgram")
        ])
        XCTAssertEqual(store.entry(forCredentialIdentifier: "deepgram.apiKey"), .idle)
    }

    // MARK: - Account definitions

    func testAccount_rejectsADefinitionItCannotHonour() {
        // No credentials: nothing to look an account up by.
        XCTAssertNil(
            ProviderBalanceAccount(
                id: "empty",
                displayName: "Empty",
                credentialIdentifiers: [],
                support: .balance,
                billingURL: "https://example.com"
            )
        )
        // A primary that is not one of its own credentials would render a
        // balance on a card that never resolves back to this account.
        XCTAssertNil(
            ProviderBalanceAccount(
                id: "mismatched",
                displayName: "Mismatched",
                credentialIdentifiers: ["a.apiKey"],
                primaryCredentialIdentifier: "b.apiKey",
                support: .balance,
                billingURL: "https://example.com"
            )
        )
        XCTAssertNotNil(
            ProviderBalanceAccount(
                id: "valid",
                displayName: "Valid",
                credentialIdentifiers: ["a.apiKey", "b.apiKey"],
                primaryCredentialIdentifier: "b.apiKey",
                support: .balance,
                billingURL: "https://example.com"
            )
        )
    }
}

/// A source that does not answer until it is released, so a refresh can be
/// superseded while it is still in flight.
final class SlowBalanceSource: ProviderBalanceSource, @unchecked Sendable {
    let accountID: String
    private let gate = DispatchSemaphore(value: 0)

    init(accountID: String) { self.accountID = accountID }

    func release() { gate.signal() }

    func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.gate.wait()
                continuation.resume(returning: ProviderBalanceSnapshot(
                    accountID: self.accountID,
                    providerDisplayName: self.accountID,
                    state: .cash(ProviderBalanceMoney(amount: 99, currencyCode: "USD")),
                    refreshedAt: Date()
                ))
            }
        }
    }
}

// MARK: - Test support

@MainActor
extension ProviderBalanceStore {
    /// Waits for the in-flight refresh to publish, without a fixed sleep.
    func waitForIdle(attempts: Int = 200) async {
        for _ in 0..<attempts {
            if entries.values.allSatisfy({ $0 != .refreshing }), !entries.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Fixed transport stubs so the model, the directory and the store can be
/// exercised without a network.
struct StubBalanceSource: ProviderBalanceSource {
    let accountID: String

    func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            accountID: accountID,
            providerDisplayName: accountID,
            state: .cash(ProviderBalanceMoney(amount: 1, currencyCode: "USD")),
            refreshedAt: Date()
        )
    }
}

final class ProviderBalanceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension XCTestCase {
    /// Answers every balance request with a fixed status and body.
    func stubProviderBalanceResponses(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        ProviderBalanceMockURLProtocol.handler = { request in
            let (status, body) = handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
    }

    func providerBalanceMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderBalanceMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
