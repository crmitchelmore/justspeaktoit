import Foundation
import XCTest

@testable import SpeakCore

/// Each balance transport against a stubbed endpoint: the success shape the
/// vendor documents, plus auth failure, quota failure, cancellation and a
/// malformed body — none of which may produce a credit figure.
final class ProviderBalanceClientTests: XCTestCase {
    override func tearDown() {
        ProviderBalanceMockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Deepgram

    func testDeepgram_reportsWalletCashForUSDBalances() async {
        stub { request in
            if request.url?.path == "/v1/projects" {
                return (200, #"{"projects":[{"project_id":"proj-1","name":"Speak"}]}"#)
            }
            XCTAssertEqual(request.url?.path, "/v1/projects/proj-1/balances")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
            return (200, #"{"balances":[{"amount":4.5,"units":"usd"},{"amount":1.25,"units":"usd"}]}"#)
        }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        XCTAssertEqual(
            snapshot.state,
            .cash(ProviderBalanceMoney(amount: Decimal(5.75), currencyCode: "USD"))
        )
        XCTAssertEqual(snapshot.accountID, "deepgram")
    }

    func testDeepgram_reportsUnknownRatherThanCreditWhenTheKeyIsRejected() async {
        stub { _ in (401, #"{"err_code":"INVALID_AUTH"}"#) }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "bad")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown for an auth failure, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.contains("401"), reason)
        XCTAssertFalse(snapshot.state.isSpendableCredit)
    }

    func testDeepgram_reportsUnknownWhenRateLimited() async {
        stub { _ in (429, "") }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown for a quota failure, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.contains("429"), reason)
    }

    func testDeepgram_reportsUnknownForAMalformedResponse() async {
        stub { request in
            request.url?.path == "/v1/projects"
                ? (200, #"{"projects":[{"project_id":"proj-1"}]}"#)
                : (200, "not json at all")
        }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        guard case .unknown = snapshot.state else {
            return XCTFail("Expected unknown for a malformed body, got \(snapshot.state)")
        }
    }

    func testDeepgram_reportsCancellationWithoutInventingABalance() async {
        ProviderBalanceMockURLProtocol.handler = { _ in throw URLError(.cancelled) }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown after cancellation, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("cancelled"), reason)
    }

    func testDeepgram_doesNotCallANonUSDBalanceCash() async {
        stub { request in
            request.url?.path == "/v1/projects"
                ? (200, #"{"projects":[{"project_id":"proj-1"}]}"#)
                : (200, #"{"balances":[{"amount":120,"units":"hour"}]}"#)
        }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        XCTAssertEqual(snapshot.state, .allowance(remaining: 120, total: nil, unit: .other("hour")))
    }

    // MARK: - Rev.ai

    func testRevAI_reportsRemainingSecondsWithAnUnknownTotal() async {
        stub { request in
            XCTAssertEqual(request.url?.path, "/speechtotext/v1/account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rev-key")
            return (200, #"{"email":"a@b.com","balance_seconds":13000}"#)
        }

        let snapshot = await RevAIBalanceClient(
            session: mockSession(),
            baseURL: URL(string: "https://rev.test")!
        ).fetchBalance(apiKey: "rev-key")

        XCTAssertEqual(snapshot.state, .allowance(remaining: 13000, total: nil, unit: .seconds))
        XCTAssertEqual(
            ProviderBalanceFormatter.summary(for: snapshot.state),
            "13,000 seconds left (limit unknown)"
        )
    }

    func testRevAI_reportsUnknownWhenTheBalanceFieldIsAbsent() async {
        stub { _ in (200, #"{"email":"a@b.com"}"#) }

        let snapshot = await RevAIBalanceClient(
            session: mockSession(),
            baseURL: URL(string: "https://rev.test")!
        ).fetchBalance(apiKey: "rev-key")

        guard case .unknown = snapshot.state else {
            return XCTFail("Expected unknown for a missing balance field, got \(snapshot.state)")
        }
    }

    func testRevAI_reportsUnknownWhenTheKeyIsForbidden() async {
        stub { _ in (403, "") }

        let snapshot = await RevAIBalanceClient(
            session: mockSession(),
            baseURL: URL(string: "https://rev.test")!
        ).fetchBalance(apiKey: "rev-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown for a forbidden key, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.contains("403"), reason)
    }

    // MARK: - ElevenLabs

    func testElevenLabs_reportsRemainingCharactersAndTheResetDate() async {
        stub { request in
            XCTAssertEqual(request.url?.path, "/v1/user/subscription")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-key")
            return (200, #"""
            {"tier":"creator","character_count":12000,"character_limit":100000,
             "next_character_count_reset_unix":1790000000}
            """#)
        }

        let snapshot = await makeElevenLabsClient().fetchBalance(apiKey: "el-key")

        XCTAssertEqual(snapshot.state, .allowance(remaining: 88000, total: 100000, unit: .characters))
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(snapshot.planName, "creator")
    }

    func testElevenLabs_treatsAMissingLimitAsUnknownRatherThanUnlimited() async {
        stub { _ in (200, #"{"tier":"enterprise","character_count":12000}"#) }

        let snapshot = await makeElevenLabsClient().fetchBalance(apiKey: "el-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown for a missing limit, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.contains("character limit"), reason)
        XCTAssertFalse(snapshot.state.isSpendableCredit)
        let rendered = ProviderBalanceFormatter.summary(for: snapshot.state)
            + (ProviderBalanceFormatter.detail(for: snapshot.state) ?? "")
        XCTAssertFalse(rendered.lowercased().contains("unlimited"), rendered)
    }

    /// An omitted usage counter is not zero usage: showing the whole plan as
    /// remaining would be the one number a user must never be shown as fact.
    func testElevenLabs_treatsAnOmittedUsageCounterAsUnknownRatherThanUnused() async {
        stub { _ in (200, #"{"tier":"creator","character_limit":100000}"#) }

        let snapshot = await makeElevenLabsClient().fetchBalance(apiKey: "el-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown for an omitted usage counter, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("used"), reason)
        XCTAssertFalse(snapshot.state.isSpendableCredit)
    }

    func testElevenLabs_labelsAFreeTierAsQuotaNotCredit() async {
        stub { _ in (200, #"{"tier":"free","character_count":5000,"character_limit":10000}"#) }

        let snapshot = await makeElevenLabsClient().fetchBalance(apiKey: "el-key")

        XCTAssertEqual(snapshot.state, .freeQuota(remaining: 5000, total: 10000, unit: .characters))
        XCTAssertFalse(snapshot.state.isSpendableCredit)
    }

    func testElevenLabs_reportsUnknownForAnUnauthorisedKey() async {
        stub { _ in (401, "") }

        let snapshot = await makeElevenLabsClient().fetchBalance(apiKey: "el-key")

        guard case .unknown = snapshot.state else {
            return XCTFail("Expected unknown for an unauthorised key, got \(snapshot.state)")
        }
    }

    func testElevenLabs_reportsUnknownAfterCancellation() async {
        ProviderBalanceMockURLProtocol.handler = { _ in throw URLError(.cancelled) }

        let snapshot = await makeElevenLabsClient().fetchBalance(apiKey: "el-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown after cancellation, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("cancelled"), reason)
    }

    // MARK: - OpenRouter

    func testOpenRouter_reportsPurchasedMinusUsedCredit() async {
        stub { request in
            XCTAssertEqual(request.url?.path, "/api/v1/credits")
            return (200, #"{"data":{"total_credits":20.0,"total_usage":7.5}}"#)
        }

        let snapshot = await OpenRouterBalanceClient(
            session: mockSession(),
            baseURL: URL(string: "https://openrouter.test")!
        ).fetchBalance(apiKey: "or-key")

        XCTAssertEqual(
            snapshot.state,
            .cash(ProviderBalanceMoney(amount: Decimal(12.5), currencyCode: "USD"))
        )
    }

    /// Usage above purchased credit is an overdrawn or postpaid account. It is
    /// not a negative wallet, and must never be marked spendable.
    func testOpenRouter_doesNotCallANegativeRemainderSpendableCash() async {
        stub { _ in (200, #"{"data":{"total_credits":5.0,"total_usage":8.25}}"#) }

        let snapshot = await OpenRouterBalanceClient(
            session: mockSession(),
            baseURL: URL(string: "https://openrouter.test")!
        ).fetchBalance(apiKey: "or-key")

        XCTAssertFalse(snapshot.state.isSpendableCredit)
        guard case .usage(let spent, _, _, let note) = snapshot.state else {
            return XCTFail("Expected usage for an overdrawn account, got \(snapshot.state)")
        }
        XCTAssertEqual(spent, ProviderBalanceMoney(amount: Decimal(8.25), currencyCode: "USD"))
        XCTAssertFalse(note.isEmpty)
    }

    func testOpenRouter_reportsUnknownWhenAFieldIsMissing() async {
        stub { _ in (200, #"{"data":{"total_credits":20.0}}"#) }

        let snapshot = await OpenRouterBalanceClient(
            session: mockSession(),
            baseURL: URL(string: "https://openrouter.test")!
        ).fetchBalance(apiKey: "or-key")

        guard case .unknown = snapshot.state else {
            return XCTFail("Expected unknown for a partial payload, got \(snapshot.state)")
        }
    }

    // MARK: - Helpers

    private func makeDeepgramClient() -> DeepgramBalanceClient {
        DeepgramBalanceClient(session: mockSession(), baseURL: URL(string: "https://deepgram.test")!)
    }

    private func makeElevenLabsClient() -> ElevenLabsBalanceClient {
        ElevenLabsBalanceClient(session: mockSession(), baseURL: URL(string: "https://elevenlabs.test")!)
    }

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        stubProviderBalanceResponses(handler)
    }

    private func mockSession() -> URLSession {
        providerBalanceMockSession()
    }
}

/// Deepgram is the one provider whose key can bill several projects, so which
/// wallets a figure covers is its own question.
final class DeepgramMultiProjectBalanceTests: XCTestCase {
    override func tearDown() {
        ProviderBalanceMockURLProtocol.handler = nil
        super.tearDown()
    }

    /// A key can reach several projects, and response order is not a choice
    /// between their wallets: the figure covers all of them or none.
    func testDeepgram_totalsEveryBillableProjectRatherThanTheFirstOne() async {
        var requestedBalancePaths: [String] = []
        stub { request in
            if request.url?.path == "/v1/projects" {
                return (
                    200,
                    #"{"projects":[{"project_id":"proj-1"},{"project_id":"proj-2"}]}"#
                )
            }
            requestedBalancePaths.append(request.url?.path ?? "")
            let amount = request.url?.path.contains("proj-1") == true ? "4.0" : "1.5"
            return (200, #"{"balances":[{"amount":\#(amount),"units":"usd"}]}"#)
        }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        XCTAssertEqual(
            snapshot.state,
            .cash(ProviderBalanceMoney(amount: Decimal(5.5), currencyCode: "USD"))
        )
        XCTAssertEqual(
            requestedBalancePaths.sorted(),
            ["/v1/projects/proj-1/balances", "/v1/projects/proj-2/balances"]
        )
    }

    func testDeepgram_reportsUnknownWhenOneProjectIsUnreadable() async {
        stub { request in
            if request.url?.path == "/v1/projects" {
                return (
                    200,
                    #"{"projects":[{"project_id":"proj-1"},{"project_id":"proj-2"}]}"#
                )
            }
            if request.url?.path.contains("proj-2") == true { return (403, "") }
            return (200, #"{"balances":[{"amount":4.0,"units":"usd"}]}"#)
        }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        // A partial sum presented as the whole would be a wrong number.
        guard case .unknown = snapshot.state else {
            return XCTFail("Expected unknown when a project cannot be read, got \(snapshot.state)")
        }
        XCTAssertFalse(snapshot.state.isSpendableCredit)
    }

    func testDeepgram_reportsUnknownWhenProjectsUseDifferentUnits() async {
        stub { request in
            if request.url?.path == "/v1/projects" {
                return (
                    200,
                    #"{"projects":[{"project_id":"proj-1"},{"project_id":"proj-2"}]}"#
                )
            }
            let units = request.url?.path.contains("proj-1") == true ? "usd" : "hours"
            return (200, #"{"balances":[{"amount":2.0,"units":"\#(units)"}]}"#)
        }

        let snapshot = await makeDeepgramClient().fetchBalance(apiKey: "dg-key")

        guard case .unknown(let reason) = snapshot.state else {
            return XCTFail("Expected unknown for mixed units, got \(snapshot.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("unit"), reason)
    }

    private func makeDeepgramClient() -> DeepgramBalanceClient {
        DeepgramBalanceClient(session: mockSession(), baseURL: URL(string: "https://deepgram.test")!)
    }

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        stubProviderBalanceResponses(handler)
    }

    private func mockSession() -> URLSession {
        providerBalanceMockSession()
    }
}
