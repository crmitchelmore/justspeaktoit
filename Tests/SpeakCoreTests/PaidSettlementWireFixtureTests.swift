import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// `workers/paid-access/fixtures/settlement-wire-v1.json`, as this client reads it.
private struct SettlementWireFixture: Decodable {
    let contract: String
    let version: Int
    let requestHeader: SettlementWireHeader
    let errors: [SettlementWireError]
}

private struct SettlementWireHeader: Decodable {
    let name: String
    let value: String
}

private struct SettlementWireError: Decodable {
    let name: String
    let status: Int
    let submitted: Bool
    let body: RawJSONObject
    let client: String
    let permitsFallback: Bool
}

/// Keeps the envelope exactly as the Worker sends it, so the client parses real bytes.
private struct RawJSONObject: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(RawJSONValue.self)
        self.data = try JSONSerialization.data(withJSONObject: value.object)
    }
}

private enum RawJSONValue: Decodable {
    case string(String)
    case object([String: RawJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            self = .object(try container.decode([String: RawJSONValue].self))
        }
    }

    var object: Any {
        switch self {
        case .string(let text): return text
        case .object(let fields): return fields.mapValues(\.object)
        }
    }
}

/// SpeakCore's side of the shared settlement wire fixture. The Worker's
/// `test/settlement-wire.test.ts` checks it sends exactly these envelopes, so a
/// code, status or envelope change on either side fails until both agree.
final class PaidSettlementWireFixtureTests: XCTestCase {
    private static let operationKey = "fixture-operation"
    private static let correlationID = "fixture-correlation"

    private func loadFixture() throws -> SettlementWireFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("workers/paid-access/fixtures/settlement-wire-v1.json")
        return try JSONDecoder().decode(SettlementWireFixture.self, from: Data(contentsOf: url))
    }

    /// The client outcome each fixture name stands for.
    private func expected(_ client: String, status: Int, submitted: Bool) -> PaidAccessError? {
        let key = submitted ? Self.operationKey : ""
        let outcomes: [String: PaidAccessError] = [
            "operationOutcome.unknown": .operationOutcome(
                .unknown, idempotencyKey: key, correlationID: Self.correlationID
            ),
            "operationOutcome.inProgress": .operationOutcome(
                .inProgress, idempotencyKey: key, correlationID: Self.correlationID
            ),
            "operationOutcome.settlementPending": .operationOutcome(
                .settlementPending, idempotencyKey: key, correlationID: Self.correlationID
            ),
            "requestNotStarted": .requestNotStarted,
            "alreadyProcessed": .alreadyProcessed,
            "quotaExceeded": .quotaExceeded,
            "entitlementRequired": .entitlementRequired,
            "paidRoutingDisabled": .paidRoutingDisabled,
            "notSignedIn": .notSignedIn,
            "tooManySessions": .tooManySessions,
            "serviceUnavailable": .serviceUnavailable(statusCode: status)
        ]
        return outcomes[client]
    }

    func testFixture_isTheVersionThisClientSpeaks() throws {
        let fixture = try self.loadFixture()
        XCTAssertEqual(fixture.contract, "paid-settlement")
        XCTAssertEqual(fixture.version, 1)
        XCTAssertFalse(fixture.errors.isEmpty)
    }

    func testEveryWorkerError_mapsToItsClientOutcomeAndFallbackRule() throws {
        for entry in try self.loadFixture().errors {
            let error = PaidAccessHTTPClient.error(
                forStatus: entry.status, body: entry.body.data,
                submittedOperation: entry.submitted ? Self.operationKey : nil, correlationID: Self.correlationID
            )
            let expected = try XCTUnwrap(self.expected(entry.client, status: entry.status, submitted: entry.submitted),
                                         "Unknown client outcome \(entry.client) in \(entry.name)")
            XCTAssertEqual(error, expected, entry.name)
            XCTAssertEqual(error.permitsSilentFallback, entry.permitsFallback, entry.name)
        }
    }

    func testSubmittedRequests_sendTheFixtureContractHeader() async throws {
        let header = try self.loadFixture().requestHeader
        StubURLProtocol.handler = { _ in .fail(URLError(.networkConnectionLost)) }
        let session = StubURLProtocol.makeSession()
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let client = PaidAccessHTTPClient(baseURL: URL(string: "https://synthetic.invalid")!, session: session)
        let account = PaidAccessSession(
            accessToken: "synthetic", accessTokenExpiresAt: .distantFuture,
            refreshToken: "synthetic", refreshTokenExpiresAt: .distantFuture, userID: "synthetic-user"
        )
        _ = try? await client.postProcess(session: account, text: "fixture", systemPrompt: nil,
                                          temperature: 0.2, idempotencyKey: Self.operationKey)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: header.name), header.value)
    }
}
