import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class PaidSettlementTests: XCTestCase {
    private let account = PaidAccessSession(
        accessToken: "synthetic", accessTokenExpiresAt: .distantFuture,
        refreshToken: "synthetic", refreshTokenExpiresAt: .distantFuture, userID: "synthetic-user"
    )

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSubmittedTransportFailureRetainsIdentityAndDoesNotPermitFallback() async throws {
        StubURLProtocol.handler = { _ in .fail(URLError(.networkConnectionLost)) }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let client = PaidAccessHTTPClient(baseURL: URL(string: "https://synthetic.invalid")!, session: session)
        for batch in [false, true] {
            let key = batch ? "batch-original-operation" : "text-original-operation"
            do {
                if batch {
                    _ = try await client.transcribe(session: self.account, audio: Data("fixture".utf8),
                                                    contentType: "audio/wav", language: nil, idempotencyKey: key)
                } else {
                    _ = try await client.postProcess(session: self.account, text: "fixture", systemPrompt: nil,
                                                    temperature: 0.2, idempotencyKey: key)
                }
                XCTFail("An unacknowledged submitted operation cannot report success")
            } catch let error as PaidAccessError {
                guard case .operationOutcome(.unknown, let retainedKey, let correlation) = error else {
                    return XCTFail("Expected uncertain operation, received \(error)")
                }
                XCTAssertEqual(retainedKey, key)
                XCTAssertFalse(error.permitsSilentFallback)
                XCTAssertEqual(correlation, StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Correlation-ID"))
                XCTAssertEqual(
                    StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Paid-Settlement-Contract"), "1"
                )
            }
        }
    }

    func testOnlyExplicitPreDispatchCodesPermitSubmittedFallback() {
        for code in ["outcome_unknown", "settlement_pending", "request_in_progress", "already_processed",
                     "unauthorized", "conflict", "unrecognised"] {
            let body = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
            let error = PaidAccessHTTPClient.error(forStatus: 401, body: body,
                                                  submittedOperation: "original-key", correlationID: "correlation")
            XCTAssertFalse(error.permitsSilentFallback, code)
        }
        for code in ["paid_routing_disabled", "entitlement_required", "quota_exceeded", "request_not_started"] {
            let body = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
            XCTAssertTrue(PaidAccessHTTPClient.error(forStatus: 409, body: body,
                                                     submittedOperation: "original-key").permitsSilentFallback, code)
        }
        XCTAssertFalse(PaidAccessHTTPClient.error(forStatus: 500, body: Data("invalid".utf8),
                                                  submittedOperation: "original-key").permitsSilentFallback)
        // The recognised compatibility code must take precedence over generic 401 handling.
        let legacy = PaidAccessHTTPClient.error(
            forStatus: 401, body: Data(#"{"error":{"code":"already_processed"}}"#.utf8)
        )
        XCTAssertEqual(legacy, .alreadyProcessed)
        XCTAssertFalse(legacy.permitsSilentFallback)
    }

    func testConfirmedResultSucceedsAndMalformedSuccessStaysUncertain() async throws {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let client = PaidAccessHTTPClient(baseURL: URL(string: "https://synthetic.invalid")!, session: session)
        for malformed in [false, true] {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = malformed ? "not-json" : #"{"text":"result","model":"fixed","provider":"fixed"}"#
                return .respond(response, Data(body.utf8))
            }
            do {
                let text = try await client.postProcess(session: self.account, text: "fixture", systemPrompt: nil,
                                                       temperature: 0.2, idempotencyKey: "original-key")
                XCTAssertFalse(malformed)
                XCTAssertEqual(text, "result")
            } catch let error as PaidAccessError {
                XCTAssertTrue(malformed)
                XCTAssertFalse(error.permitsSilentFallback)
            }
        }
    }

    func testOccupiedAllowanceIsNotCountedTwiceOrInventedAsMeasuredForOldSnapshots() throws {
        let base: [String: Any] = [
            "period": "2026-10", "audio_seconds_used": 50, "audio_seconds_limit": 100,
            "tokens_used": 50, "tokens_limit": 100, "active_sessions": 0, "max_concurrent_sessions": 2
        ]
        let old = try JSONDecoder().decode(
            UsagePayload.self, from: JSONSerialization.data(withJSONObject: base)
        ).snapshot
        XCTAssertEqual(old.audioFractionUsed, 0.5)
        XCTAssertNil(old.audioSecondsMeasured)
        XCTAssertNil(old.audioSecondsHeld)
        XCTAssertEqual(old.tokenAllowanceSummary, "50 of 100 tokens of allowance in use")
        var detailed = base
        detailed["audio_seconds_measured"] = 20
        detailed["audio_seconds_held"] = 30
        detailed["tokens_measured"] = 20
        detailed["tokens_held"] = 30
        let current = try JSONDecoder().decode(UsagePayload.self,
                                              from: JSONSerialization.data(withJSONObject: detailed)).snapshot
        XCTAssertEqual(current.audioSecondsLimit - current.audioSecondsUsed, 50)
        XCTAssertEqual(current.audioSecondsMeasured, 20)
        XCTAssertEqual(current.audioSecondsHeld, 30)
        XCTAssertEqual(current.audioFractionUsed, old.audioFractionUsed)
        XCTAssertEqual(current.tokenAllowanceSummary, "50 of 100 tokens of allowance in use (20 measured; 30 held)")
    }
}
