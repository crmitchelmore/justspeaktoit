import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// The shared balance transports on the portable graph, as Windows and Linux
/// run them: the vendor endpoint and auth header each one sends, the figure it
/// parses, and that a key never leaves the auth header.
final class ProviderBalancePortableClientTests: XCTestCase {
    private let key = "sk-synthetic-balance-key-0123456789"

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSharedSourcesCoverEveryReadableAccountOnce() {
        let readable = ProviderBalanceDirectory.accounts.filter { $0.support == .balance }.map(\.id)
        XCTAssertEqual(Set(ProviderBalanceSources.accountIDs), Set(readable))
        XCTAssertEqual(ProviderBalanceSources.accountIDs.count, Set(ProviderBalanceSources.accountIDs).count)
    }

    func testOpenRouterRequestShapeAndRemainingCredit() async throws {
        stub { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            return (200, #"{"data":{"total_credits":20,"total_usage":7.5}}"#)
        }

        let snapshot = await source("openrouter").fetchBalance(apiKey: key)

        XCTAssertEqual(snapshot.state, .cash(ProviderBalanceMoney(amount: Decimal(12.5), currencyCode: "USD")))
        try assertOnlyAuthHeaderCarriesKey(expected: ["Authorization": "Bearer \(key)"])
    }

    func testRevAIRequestShapeAndRemainingSeconds() async throws {
        stub { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.rev.ai/speechtotext/v1/account")
            return (200, #"{"email":"a@b.test","balance_seconds":600}"#)
        }

        let snapshot = await source("revai").fetchBalance(apiKey: key)

        XCTAssertEqual(snapshot.state, .allowance(remaining: 600, total: nil, unit: .seconds))
        try assertOnlyAuthHeaderCarriesKey(expected: ["Authorization": "Bearer \(key)"])
    }

    func testElevenLabsRequestShapeAndCharacterAllowance() async throws {
        stub { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/user/subscription")
            return (200, #"{"tier":"creator","character_count":1000,"character_limit":5000}"#)
        }

        let snapshot = await source("elevenlabs").fetchBalance(apiKey: key)

        XCTAssertEqual(snapshot.state, .allowance(remaining: 4000, total: 5000, unit: .characters))
        try assertOnlyAuthHeaderCarriesKey(expected: ["xi-api-key": key])
    }

    func testDeepgramWalksProjectsWithTokenAuth() async throws {
        stub { request in
            if request.url?.path == "/v1/projects" {
                XCTAssertEqual(request.url?.host, "api.deepgram.com")
                return (200, #"{"projects":[{"project_id":"p1"}]}"#)
            }
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/projects/p1/balances")
            return (200, #"{"balances":[{"amount":3.25,"units":"usd"}]}"#)
        }

        let snapshot = await source("deepgram").fetchBalance(apiKey: key)

        XCTAssertEqual(snapshot.state, .cash(ProviderBalanceMoney(amount: Decimal(3.25), currencyCode: "USD")))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        try assertOnlyAuthHeaderCarriesKey(expected: ["Authorization": "Token \(key)"])
    }

    func testFailuresReportUnknownWithoutTheKey() async {
        let failures: [(Int, String)] = [
            (401, #"{"error":"bad key \#(key)"}"#), (403, ""), (404, ""), (429, ""), (500, ""), (200, "not json")
        ]
        for (status, body) in failures {
            for accountID in ProviderBalanceSources.accountIDs {
                stub { _ in (status, body) }
                let snapshot = await source(accountID).fetchBalance(apiKey: key)
                guard case .unknown(let reason) = snapshot.state else {
                    XCTFail("\(accountID) HTTP \(status) gave \(snapshot.state)")
                    continue
                }
                XCTAssertFalse(snapshot.state.isSpendableCredit)
                assertNoKey(in: reason, "\(accountID) HTTP \(status)")
                assertNoKey(in: String(describing: snapshot), "\(accountID) HTTP \(status)")
            }
        }
    }

    func testTransportErrorReportsUnknownWithoutTheKey() async {
        for accountID in ProviderBalanceSources.accountIDs {
            StubURLProtocol.respond { _ in throw URLError(.notConnectedToInternet) }
            let snapshot = await source(accountID).fetchBalance(apiKey: key)
            guard case .unknown(let reason) = snapshot.state else {
                XCTFail("\(accountID) offline gave \(snapshot.state)")
                continue
            }
            assertNoKey(in: reason, accountID)
            assertNoKey(in: ProviderBalanceFormatter.detail(for: snapshot.state) ?? "", accountID)
        }
    }

    // MARK: - Helpers

    private func source(_ accountID: String) -> any ProviderBalanceSource {
        let sources = ProviderBalanceSources.defaults(session: StubURLProtocol.makeSession())
        guard let source = sources.first(where: { $0.accountID == accountID }) else {
            preconditionFailure("No shared balance source for \(accountID)")
        }
        return source
    }

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        StubURLProtocol.reset()
        StubURLProtocol.respond { request in
            let (status, body) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    /// Every request is a GET with no body, and the key appears in exactly the
    /// expected auth header: never the URL, a query item or another header.
    private func assertOnlyAuthHeaderCarriesKey(
        expected: [String: String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let requests = StubURLProtocol.recordedRequests
        XCTAssertFalse(requests.isEmpty, file: file, line: line)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET", file: file, line: line)
            XCTAssertTrue(StubURLProtocol.body(of: request).isEmpty, file: file, line: line)
            assertNoKey(in: request.url?.absoluteString ?? "", "URL", file: file, line: line)
            let headers = request.allHTTPHeaderFields ?? [:]
            for (name, value) in expected {
                XCTAssertEqual(request.value(forHTTPHeaderField: name), value, file: file, line: line)
            }
            let carrying = headers.filter { $0.value.contains(key) }.map { $0.key.lowercased() }
            XCTAssertEqual(Set(carrying), Set(expected.keys.map { $0.lowercased() }), file: file, line: line)
        }
    }

    private func assertNoKey(
        in text: String, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(text.contains(key), "\(context) leaked the key: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("0123456789"), "\(context) leaked part of the key", file: file, line: line)
    }
}
