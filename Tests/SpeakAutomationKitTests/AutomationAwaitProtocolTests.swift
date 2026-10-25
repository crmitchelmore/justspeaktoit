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

    #if canImport(CryptoKit)
    func testAwaitMCPIdentity_PreservesTypedAndFullIDsWithoutChangingLegacyKeys() throws {
        XCTAssertNotEqual(try MCPRequestHandler.awaitRequestID(for: 1),
                          try MCPRequestHandler.awaitRequestID(for: "1"))
        let prefix = String(repeating: "a", count: 512)
        let first = try MCPRequestHandler.awaitRequestID(for: prefix + "first")
        let second = try MCPRequestHandler.awaitRequestID(for: prefix + "second")
        XCTAssertNotEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, AutomationLimits.maxIdentifierLength)
        XCTAssertEqual(try MCPRequestHandler.awaitRequestID(for: prefix + "first"), first)
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
