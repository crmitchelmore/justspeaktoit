import XCTest

@testable import SpeakCore

/// Covers the protocol-version compatibility policy used by the transport server
/// when validating a client's `HelloMessage` (issue #622).
final class TransportProtocolVersionTests: XCTestCase {

    // MARK: - Compatibility policy (exact match)

    func testHelloWithCurrentVersion_isCompatible() {
        let hello = HelloMessage(
            protocolVersion: SpeakTransportProtocolVersion,
            deviceName: "iPhone",
            deviceId: "device-1"
        )
        XCTAssertTrue(hello.isProtocolVersionCompatible)
    }

    func testHelloDefaultInit_isCompatible() {
        let hello = HelloMessage(deviceName: "iPhone", deviceId: "device-1")
        XCTAssertTrue(hello.isProtocolVersionCompatible)
    }

    func testHelloWithOlderVersion_isIncompatible() {
        let hello = HelloMessage(
            protocolVersion: SpeakTransportProtocolVersion - 1,
            deviceName: "iPhone",
            deviceId: "device-1"
        )
        XCTAssertFalse(hello.isProtocolVersionCompatible)
    }

    func testHelloWithNewerVersion_isIncompatible() {
        let hello = HelloMessage(
            protocolVersion: SpeakTransportProtocolVersion + 1,
            deviceName: "iPhone",
            deviceId: "device-1"
        )
        XCTAssertFalse(hello.isProtocolVersionCompatible)
    }

    func testDecodedHelloWithMismatchedVersion_isIncompatible() throws {
        let version = SpeakTransportProtocolVersion + 7
        let json = """
        {"type":"hello","payload":{"protocolVersion":\(version),"deviceName":"Phone","deviceId":"d1"}}
        """
        let decoded = try JSONDecoder().decode(TransportMessage.self, from: Data(json.utf8))
        guard case .hello(let hello) = decoded else {
            XCTFail("Expected .hello, got \(decoded)")
            return
        }
        XCTAssertFalse(hello.isProtocolVersionCompatible)
    }

    // MARK: - Typed mismatch error

    func testProtocolMismatchError_usesSameCodeAsStaticConstant() {
        let error = ErrorMessage.protocolMismatch(clientVersion: 99)
        XCTAssertEqual(error.code, 400)
        XCTAssertEqual(error.code, ErrorMessage.protocolMismatch.code)
    }

    func testProtocolMismatchError_reportsBothVersions() {
        let error = ErrorMessage.protocolMismatch(clientVersion: 99, serverVersion: 3)
        XCTAssertTrue(error.message.contains("v99"), "Missing client version in: \(error.message)")
        XCTAssertTrue(error.message.contains("v3"), "Missing server version in: \(error.message)")
    }

    func testProtocolMismatchError_defaultsServerVersionToCurrent() {
        let error = ErrorMessage.protocolMismatch(clientVersion: 99)
        XCTAssertTrue(
            error.message.contains("v\(SpeakTransportProtocolVersion)"),
            "Missing current server version in: \(error.message)"
        )
    }

    func testProtocolMismatchError_roundTripsThroughTransportMessage() throws {
        let original = TransportMessage.error(.protocolMismatch(clientVersion: 42))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TransportMessage.self, from: data)
        guard case .error(let error) = decoded else {
            XCTFail("Expected .error, got \(decoded)")
            return
        }
        XCTAssertEqual(error.code, ErrorMessage.protocolMismatch.code)
        XCTAssertTrue(error.message.contains("v42"))
    }
}
