import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// Round-trip coverage of the automation wire contract: what one side writes,
/// the other must read back unchanged, and bad payloads must be rejected.
final class AutomationTransportTests: XCTestCase {
    // MARK: - Request / response round trip

    func testRequest_roundTripsOverTheWire() throws {
        let request = AutomationRequest(
            id: "req-1",
            command: .transcribeFile,
            path: "/tmp/a.m4a",
            profile: "code",
            provider: "deepgram",
            timeout: 30
        )
        let data = try AutomationCoding.encoder().encode(request)
        let decoded = try AutomationCoding.decoder().decode(AutomationRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.schemaVersion, AutomationSchema.currentVersion)
    }

    func testClientResponseGrace_outlivesTheCommandDeadline() {
        XCTAssertGreaterThan(UnixSocketAutomationClient.responseGracePeriod, 0)
        XCTAssertLessThanOrEqual(UnixSocketAutomationClient.responseGracePeriod, 2)
    }

    func testResponse_roundTripsWithISO8601Dates() throws {
        let entry = AutomationHistoryEntry(
            id: "H1",
            text: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "nova-3",
            durationSeconds: 3,
            wordCount: 1
        )
        let response = AutomationResponse.success(
            id: "req-2",
            command: .history,
            result: AutomationResult(entries: [entry])
        )
        let data = try AutomationCoding.encoder().encode(response)
        let wire = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(
            wire.contains("2023-11-14T"),
            "Dates must be ISO-8601 strings so shell consumers can read them"
        )
        let decoded = try AutomationCoding.decoder().decode(AutomationResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }

    func testUnknownResponseFields_areIgnoredByOlderClients() throws {
        // Simulates a newer app adding a field: decoding must not fail.
        let json = """
        {"schemaVersion":1,"id":"x","command":"status","ok":true,
         "result":{"sessionActive":false,"futureField":"ignored"}}
        """
        let decoded = try AutomationCoding.decoder().decode(AutomationResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.result?.sessionActive, false)
    }

    // MARK: - Validation

    func testTranscribeWithoutPath_isRejected() {
        XCTAssertThrowsError(try AutomationRequest(command: .transcribeFile).validated()) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }
    }

    func testOversizedPath_isRejected() {
        let request = AutomationRequest(
            command: .transcribeFile,
            path: String(repeating: "a", count: AutomationLimits.maxPathLength + 1)
        )
        XCTAssertThrowsError(try request.validated()) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }
    }

    func testHistoryLimitOutOfRange_isRejected() {
        let request = AutomationRequest(command: .history, limit: AutomationLimits.maxHistoryLimit + 1)
        XCTAssertThrowsError(try request.validated()) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }
    }

    func testMissingLimit_defaultsWithoutFailing() throws {
        let request = try AutomationRequest(command: .history).validated()
        XCTAssertEqual(request.resolvedLimit, AutomationLimits.defaultHistoryLimit)
    }

    func testSchemaMismatch_isRejectedWithAnActionableMessage() {
        let request = AutomationRequest(schemaVersion: 99, command: .status)
        XCTAssertThrowsError(try request.validated()) { error in
            let automationError = error as? AutomationError
            XCTAssertEqual(automationError?.code, .schemaMismatch)
            XCTAssertTrue(automationError?.message.contains("Update") == true)
        }
    }

    func testTimeout_isClampedToTheCeiling() {
        let request = AutomationRequest(command: .status, timeout: AutomationLimits.maxTimeout * 10)
        XCTAssertEqual(request.resolvedTimeout, AutomationLimits.maxTimeout)
    }

    func testTranscribeTimeout_defaultsLongerThanInteractiveCommands() {
        XCTAssertEqual(
            AutomationRequest(command: .transcribeFile, path: "/tmp/a.m4a").resolvedTimeout,
            AutomationLimits.transcriptionTimeout
        )
        XCTAssertEqual(AutomationRequest(command: .status).resolvedTimeout, AutomationLimits.defaultTimeout)
    }

    // MARK: - Framing

    func testFraming_roundTrips() throws {
        let payload = Data("hello".utf8)
        let framed = try AutomationFraming.frame(payload)
        XCTAssertEqual(framed.count, payload.count + AutomationFraming.prefixLength)

        let length = try AutomationFraming.payloadLength(
            from: framed.prefix(AutomationFraming.prefixLength)
        )
        XCTAssertEqual(length, payload.count)
        XCTAssertEqual(framed.dropFirst(AutomationFraming.prefixLength), payload)
    }

    func testFraming_rejectsOversizedPayload() {
        let payload = Data(repeating: 0, count: AutomationLimits.maxFrameBytes + 1)
        XCTAssertThrowsError(try AutomationFraming.frame(payload))
    }

    func testFraming_rejectsAnAbsurdDeclaredLengthBeforeAllocating() {
        let prefix = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try AutomationFraming.payloadLength(from: prefix)) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }
    }

    func testFraming_rejectsZeroLength() {
        XCTAssertThrowsError(try AutomationFraming.payloadLength(from: Data([0, 0, 0, 0])))
    }

    func testFraming_rejectsTruncatedPrefix() {
        XCTAssertThrowsError(try AutomationFraming.payloadLength(from: Data([0, 1])))
    }

    // MARK: - Endpoint

    func testSocketPath_honoursTheEnvironmentOverride() {
        let path = AutomationEndpoint.socketPath(
            environment: [AutomationEndpoint.environmentKey: "/tmp/custom.sock"]
        )
        XCTAssertEqual(path, "/tmp/custom.sock")
    }

    func testSocketPath_defaultsUnderApplicationSupport() {
        let path = AutomationEndpoint.socketPath(environment: [:])
        XCTAssertTrue(path.hasSuffix("SpeakApp/Automation/automation.sock"))
    }

    func testSocketPath_fitsThePlatformLimitForATypicalHome() {
        // Asserting against the real home directory would fail on a long CI or
        // sandbox container path for reasons unrelated to the code under test.
        let path = AutomationEndpoint.socketPath(
            environment: [:],
            fileManager: FixedSupportDirectoryFileManager(base: "/Users/example/Library/Application Support")
        )
        XCTAssertLessThan(path.utf8.count, 104, "UNIX socket paths are capped by the platform")
    }

    // MARK: - Unavailable app

    func testClient_reportsAppUnavailableWhenNothingIsListening() {
        let client = UnixSocketAutomationClient(socketPath: "/tmp/speak-automation-does-not-exist.sock")
        XCTAssertThrowsError(try client.send(AutomationRequest(command: .status))) { error in
            let automationError = error as? AutomationError
            XCTAssertEqual(automationError?.code, .appUnavailable)
            let message = automationError?.message ?? ""
            // A missing socket means either the app is closed or automation is
            // off; the message must name both and point at the switch.
            XCTAssertTrue(message.contains("isn't running"), message)
            XCTAssertTrue(message.contains("automation is turned off"), message)
            XCTAssertTrue(message.contains("Settings → General → Automation"), message)
            XCTAssertTrue(message.contains("/tmp/speak-automation-does-not-exist.sock"), message)
        }
    }

    func testClient_validatesBeforeOpeningASocket() {
        let client = UnixSocketAutomationClient(socketPath: "/tmp/speak-automation-does-not-exist.sock")
        XCTAssertThrowsError(try client.send(AutomationRequest(command: .transcribeFile))) { error in
            XCTAssertEqual(
                (error as? AutomationError)?.code,
                .invalidArgument,
                "Bad arguments must fail before the connection attempt"
            )
        }
    }

    // MARK: - Secret hygiene

    func testWireTypes_carryNoCredentialFields() throws {
        let response = AutomationResponse.success(
            id: "req",
            command: .transcribeFile,
            result: AutomationResult(text: "hello", model: "nova-3", durationSeconds: 1)
        )
        let encoded = try AutomationCoding.encoder().encode(response)
        let json = try XCTUnwrap(String(bytes: encoded, encoding: .utf8)).lowercased()
        for forbidden in ["apikey", "api_key", "token", "secret", "authorization"] {
            XCTAssertFalse(json.contains(forbidden), "Automation payloads must never carry \(forbidden)")
        }
    }
}

/// Pins the Application Support directory so socket-path tests do not depend on
/// the length of the running user's home directory.
private final class FixedSupportDirectoryFileManager: FileManager {
    private let base: String

    init(base: String) {
        self.base = base
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask)
        -> [URL] {
        [URL(fileURLWithPath: self.base, isDirectory: true)]
    }
}
