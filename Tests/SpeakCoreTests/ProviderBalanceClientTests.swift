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
