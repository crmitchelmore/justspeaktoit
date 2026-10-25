import Foundation
import SpeakCore
import XCTest
@testable import SpeakAutomationKit

final class AutomationAwaitProtocolTests: XCTestCase {
    func testOldPayloads_DecodeWithoutNewFieldsAndInitializerAritySurvives() throws {
        let make: (Int, String, AutomationCommand, String?, String?, String?, Int?, TimeInterval?) -> AutomationRequest
            = AutomationRequest.init
        let result: (String?, String?, TimeInterval?, Bool?, String?, [AutomationHistoryEntry]?) -> AutomationResult
            = AutomationResult.init
        let plan: (AutomationCommand, String?, Int?, TimeInterval?, Bool) -> CLIPlan = CLIPlan.init
        XCTAssertNil(make(1, "old", .status, nil, nil, nil, nil, nil).captureID)
        XCTAssertNil(result(nil, nil, nil, nil, nil, nil).entry)
        XCTAssertNil(plan(.status, nil, nil, nil, false).captureID)
        let request = try AutomationCoding.decoder().decode(AutomationRequest.self, from: Data(
            #"{"schemaVersion":1,"id":"old","command":"status"}"#.utf8))
        XCTAssertNil(request.captureID)
        XCTAssertNil(request.sinceID)
        XCTAssertNil(try AutomationCoding.decoder().decode(AutomationResult.self, from: Data("{}".utf8)).captureID)
    }

    func testAwaitTimeoutAndIdentity_AreValidatedOnWireBoundary() throws {
        let capture = UUID().uuidString
        XCTAssertEqual(try AutomationRequest(command: .awaitTranscript, captureID: capture).validated().resolvedTimeout,
            60)
        XCTAssertNoThrow(try AutomationRequest(command: .awaitTranscript, timeout: 600, captureID: capture).validated())
        for timeout in [0, -1, 600.01, .infinity, .nan] {
            XCTAssertThrowsError(try AutomationRequest(command: .awaitTranscript, timeout: timeout,
                                                      captureID: capture).validated())
        }
        XCTAssertThrowsError(try AutomationRequest(command: .awaitTranscript).validated())
        XCTAssertThrowsError(try AutomationRequest(command: .awaitTranscript, captureID: "not-uuid").validated())
        XCTAssertThrowsError(try AutomationRequest(command: .awaitTranscript, captureID: capture,
                                                  sinceID: "deleted?").validated())
        XCTAssertThrowsError(try AutomationRequest(command: .status, captureID: capture).validated())
        XCTAssertThrowsError(try AutomationRequest(command: .awaitTranscript, path: "/tmp/unrelated",
                                                  captureID: capture).validated())
    }

    func testAwaitCLI_RequiresNamedCaptureAndPreservesCursorAndBounds() throws {
        let capture = UUID().uuidString
        let cursor = UUID().uuidString
        guard case .run(let plan) = try CommandLineParser.parse([
            "await", "--capture-id", capture, "--since-id", cursor, "--timeout", "600", "--json"
        ]) else { return XCTFail("Expected await plan") }
        XCTAssertEqual(plan.command, .awaitTranscript)
        XCTAssertEqual(plan.request().captureID, capture)
        XCTAssertEqual(plan.request().sinceID, cursor)
        XCTAssertEqual(plan.request().resolvedTimeout, 600)
        for arguments in [["await"], ["await", "--capture-id", capture, "--timeout", "601"],
                          ["await", "--capture-id", capture, "--timeout", "inf"],
                          ["await", "--capture-id", capture, "--since-id", "x"]] {
            XCTAssertThrowsError(try CommandLineParser.parse(arguments))
        }
    }

    func testAwaitResult_RoundTripsFrozenIdentityAndUsesTextOutput() throws {
        let capture = UUID().uuidString
        let entry = AutomationHistoryEntry(id: capture, text: "fixture result",
            createdAt: Date(timeIntervalSince1970: 0),
                                           model: "local/test", durationSeconds: 1, wordCount: 2)
        let result = AutomationResult(text: entry.text, captureID: capture, entry: entry)
        XCTAssertEqual(try AutomationCoding.decoder().decode(AutomationResult.self,
            from: AutomationCoding.encoder().encode(result)), result)
        XCTAssertEqual(CLIRunner.humanText(for: result, command: .awaitTranscript), "fixture result\n")
    }

    func testRawAwaitIdentity_PreservesPortableTypesPrecisionAndCancellationKeys() throws {
        let cases: [(String, String?)] = [
            ("1", "n:1"), ("1.0", "n:1"), ("-1", "n:-1"), ("0", "n:0"),
            ("9007199254740993", "n:9007199254740993"),
            ("-9223372036854775808", "n:-9223372036854775808"),
            ("-9223372036854775809", nil),
            ("18446744073709551614", "n:18446744073709551614"),
            ("18446744073709551615", "n:18446744073709551615"),
            ("18446744073709551616", nil), ("18446744073709551617", nil), ("1e100", nil),
            ("1.25", "n:1.25"), (#""1""#, "s:1"),
            ("true", nil), ("false", nil), ("null", nil), (#"{"nested":1}"#, nil), ("[]", nil)
        ]
        for (rawID, expected) in cases {
            let request = Data(("{\"id\":" + rawID + "}").utf8)
            let cancellation = Data(("{\"params\":{\"requestId\":" + rawID + "}}").utf8)
            XCTAssertEqual(MCPRequestHandler.awaitIdentity(in: request), expected)
            XCTAssertEqual(MCPRequestHandler.awaitIdentity(in: cancellation, cancellation: true), expected)
        }
        XCTAssertNil(MCPRequestHandler.awaitIdentity(in: Data("{}".utf8)))
        let first = MCPRequestHandler.awaitIdentity(in: Data(#"{"id":18446744073709551614}"#.utf8))
        let second = MCPRequestHandler.awaitIdentity(in: Data(#"{"id":18446744073709551615}"#.utf8))
        XCTAssertNotEqual(first, second)
        let projected = try JSONDecoder().decode(MCPJSONValue.self, from: Data("18446744073709551615".utf8))
        XCTAssertEqual(projected, .unsigned(UInt64.max))
        XCTAssertEqual(projected.foundationValue as? UInt64, UInt64.max)
    }

    #if canImport(CryptoKit)
    func testAwaitMCPIdentity_PreservesTypedAndFullIDsWithoutChangingLegacyKeys() throws {
        XCTAssertNotEqual(try MCPRequestHandler.awaitRequestID(for: "n:1"),
                          try MCPRequestHandler.awaitRequestID(for: "s:1"))
        let prefix = String(repeating: "a", count: 512)
        let first = try MCPRequestHandler.awaitRequestID(for: "s:" + prefix + "first")
        let second = try MCPRequestHandler.awaitRequestID(for: "s:" + prefix + "second")
        XCTAssertNotEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, AutomationLimits.maxIdentifierLength)
        XCTAssertEqual(try MCPRequestHandler.awaitRequestID(for: "s:" + prefix + "first"), first)
        XCTAssertEqual(MCPRequestHandler.requestID(for: 1), MCPRequestHandler.requestID(for: "1"))
    }
    #endif

    func testCancellationBeforeInstall_IsStickyAndUninstallPreventsLaterFDAction() {
        let token = AutomationRequestCancellation()
        token.cancel()
        let actions = AwaitActionCounter()
        token.install { actions.increment() }
        token.cancel()
        XCTAssertEqual(actions.value, 1)
        token.uninstall()
        let later = AutomationRequestCancellation()
        later.install { actions.increment() }
        later.uninstall()
        later.cancel()
        XCTAssertEqual(actions.value, 1)
    }
}

private final class AwaitActionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { self.lock.withLock { self.count } }
    func increment() { self.lock.withLock { self.count += 1 } }
}
