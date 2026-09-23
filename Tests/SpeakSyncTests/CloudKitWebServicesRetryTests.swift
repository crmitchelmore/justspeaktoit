import Foundation
import XCTest

@testable import SpeakSync

/// Bounded retry: which failures wait, for how long, and when a call gives up.
final class CloudKitWebServicesRetryTests: XCTestCase {
    private let zone = SyncSchema.zoneName

    func testThrottledRequestWaitsForTheServersRetryAfter() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.serverError("THROTTLED", status: 429, retryAfter: 2))
        let recorder = RecordingSleeper()
        let client = try recordingClient(transport, recorder)

        _ = try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"])

        let waits = await recorder.requested
        XCTAssertEqual(waits, [.seconds(2)])
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    func testTransientFailuresBackOffExponentiallyThenGiveUp() async throws {
        let transport = ScriptedCloudKitTransport()
        for _ in 0..<4 {
            await transport.enqueue(CloudKitWebFixture.serverError("TRY_AGAIN_LATER", status: 503))
        }
        let recorder = RecordingSleeper()
        let client = try recordingClient(transport, recorder)

        do {
            _ = try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"])
            XCTFail("Expected the retries to be exhausted")
        } catch let CloudKitWebServicesError.server(error) {
            XCTAssertEqual(error.code, .tryAgainLater)
        }
        let waits = await recorder.requested
        XCTAssertEqual(waits, [.seconds(1), .seconds(2), .seconds(4)])
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, CloudKitWebRetryPolicy.standard.maximumAttempts)
    }

    func testServerDelayBeyondTheCapAndPermanentErrorsAreNotWaitedFor() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.serverError("THROTTLED", status: 429, retryAfter: 600))
        await transport.enqueue(CloudKitWebFixture.serverError("BAD_REQUEST", status: 400))
        let recorder = RecordingSleeper()
        let client = try recordingClient(transport, recorder)

        for expected in [CloudKitWebServerErrorCode.throttled, .badRequest] {
            do {
                _ = try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"])
                XCTFail("Expected \(expected.rawValue)")
            } catch let CloudKitWebServicesError.server(error) {
                XCTAssertEqual(error.code, expected)
            }
        }
        let waits = await recorder.requested
        XCTAssertTrue(waits.isEmpty)
    }

    func testTransportTimeoutsAndGatewayErrorsRetryButOtherTransportFailuresDoNot() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(failure: CloudKitWebServicesTransportError.timedOut)
        await transport.enqueue(CloudKitWebServicesHTTPResponse(statusCode: 502, headers: [:], body: Data()))
        await transport.enqueue(CloudKitWebFixture.records([]))
        let refused = CloudKitWebServicesTransportError.connectionFailed(
            retryable: false,
            description: "URLError -1009"
        )
        await transport.enqueue(failure: refused)
        let recorder = RecordingSleeper()
        let client = try recordingClient(transport, recorder)

        _ = try await client.lookupRecords(zoneName: zone, recordNames: ["recovers"])
        do {
            _ = try await client.lookupRecords(zoneName: zone, recordNames: ["offline"])
            XCTFail("Expected the non-retryable failure")
        } catch {
            XCTAssertEqual(error as? CloudKitWebServicesError, .transport(refused))
            XCTAssertEqual(error.localizedDescription, "Could not reach iCloud.")
        }
        let waits = await recorder.requested
        XCTAssertEqual(waits, [.seconds(1), .seconds(2)])
    }

    func testCancellationDuringBackoffSendsNoFurtherRequest() async throws {
        let transport = ScriptedCloudKitTransport()
        await transport.enqueue(CloudKitWebFixture.serverError("TRY_AGAIN_LATER", status: 503))
        let sleeper = HeldSleeper()
        let store = HeldTokenStore(token: "synthetic")
        let client = try makeTestClient(store: store, transport: transport, sleeper: sleeper)

        let operation = Task { try await client.lookupRecords(zoneName: zone, recordNames: ["record-a"]) }
        try await eventually { await sleeper.waiterCount == 1 }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await client.lookupRecords(zoneName: zone, recordNames: ["next"])
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2, "the cancelled operation must not retry")
    }

    func testRetryPolicyBackoffIsExponentialAndCapped() {
        let policy = CloudKitWebRetryPolicy(
            maximumAttempts: 0,
            initialBackoff: .milliseconds(500),
            maximumBackoff: .seconds(3),
            maximumServerDelay: .seconds(10)
        )
        XCTAssertEqual(policy.maximumAttempts, 1)
        XCTAssertEqual((1...5).map(policy.backoff(afterAttempt:)), [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(3), .seconds(3)
        ])
    }

    private func recordingClient(
        _ transport: ScriptedCloudKitTransport,
        _ recorder: RecordingSleeper
    ) throws -> CloudKitWebServicesClient {
        try makeTestClient(store: HeldTokenStore(token: "synthetic"), transport: transport, recorder: recorder)
    }
}
