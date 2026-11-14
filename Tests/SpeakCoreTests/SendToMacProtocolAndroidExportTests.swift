import CryptoKit
import Foundation
import XCTest

@testable import SpeakCore

/// Android's Send to Mac sender reads a committed JSON asset of protocol
/// constants and test vectors. This keeps the asset current and proves, with the
/// Mac's own types, that what Android sends is what the Mac accepts.
final class SendToMacProtocolAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/send_to_mac_protocol.json")
    }

    private var macDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testAndroidAssetMatchesProtocol() throws {
        let expected = try SendToMacProtocolAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_SEND_TO_MAC_PROTOCOL_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        let committed = try Data(contentsOf: assetURL)
        XCTAssertEqual(
            committed, expected,
            "android/app/src/main/assets/send_to_mac_protocol.json is stale. Regenerate with "
                + "scripts/update-android-assets"
        )
    }

    func testAssetIsDeterministic() throws {
        XCTAssertEqual(try SendToMacProtocolAndroidExport.json(), try SendToMacProtocolAndroidExport.json())
    }

    func testPhoneKeySharesDecodeOnTheMac() throws {
        let pairing = try SendToMacProtocolAndroidExport.handshake(
            secret: .code(SendToMacProtocolAndroidExport.pairingCode),
            issuing: SendToMacProtocolAndroidExport.credential
        )
        let codeShare = try XCTUnwrap(TransportKeyShare.decode(Data(pairing.clientFrame.utf8)))
        XCTAssertEqual(codeShare.protocolVersion, SpeakTransportProtocolVersion)
        XCTAssertEqual(codeShare.requestsCredential, true)
        XCTAssertNil(codeShare.credentialID)

        let credential = SendToMacProtocolAndroidExport.credential
        let later = try SendToMacProtocolAndroidExport.handshake(secret: .credential(credential), issuing: nil)
        let credentialShare = try XCTUnwrap(TransportKeyShare.decode(Data(later.clientFrame.utf8)))
        XCTAssertEqual(credentialShare.credentialID, credential.id)
        XCTAssertNil(credentialShare.requestsCredential)
    }

    func testMacAcceptsThePhonesPairingProofAndIssuesTheCredential() throws {
        let code = SendToMacProtocolAndroidExport.pairingCode
        let credential = SendToMacProtocolAndroidExport.credential
        let vector = try SendToMacProtocolAndroidExport.handshake(secret: .code(code), issuing: credential)
        let proof = try self.macProof(for: vector)
        XCTAssertTrue(proof.requestsCredential)
        XCTAssertFalse(proof.verifies(pairingCode: "000000"))
        XCTAssertTrue(proof.verifies(pairingCode: code))

        var phone = try self.phoneKeys(for: vector, secret: .code(code))
        let opened = try phone.inbound.open(self.bytes(vector.serverFinished))
        XCTAssertEqual(try TransportKeySchedule.credential(inServerFinished: opened), credential)

        var mac = try XCTUnwrap(proof.acceptedKeys)
        _ = try mac.outbound.seal(TransportKeySchedule.serverFinished(issuing: credential))
        let phoneMessage = try mac.inbound.open(self.bytes(vector.phoneMessage.sealed))
        XCTAssertEqual(phoneMessage, Data(vector.phoneMessage.json.utf8))
        let macMessage = try phone.inbound.open(self.bytes(vector.macMessage.sealed))
        XCTAssertEqual(macMessage, Data(vector.macMessage.json.utf8))
    }

    func testMacAcceptsTheCredentialProofWithoutTheCode() throws {
        let credential = SendToMacProtocolAndroidExport.credential
        let vector = try SendToMacProtocolAndroidExport.handshake(secret: .credential(credential), issuing: nil)
        let proof = try self.macProof(for: vector)
        XCTAssertEqual(proof.credentialID, credential.id)
        XCTAssertFalse(proof.verifies(pairingCode: SendToMacProtocolAndroidExport.pairingCode))
        XCTAssertTrue(proof.verifies(credential: credential))

        var phone = try self.phoneKeys(for: vector, secret: .credential(credential))
        let opened = try phone.inbound.open(self.bytes(vector.serverFinished))
        XCTAssertNil(try TransportKeySchedule.credential(inServerFinished: opened))
    }

    func testPhoneMessagesDecodeOnTheMac() throws {
        let messages = SendToMacProtocolAndroidExport.phoneMessages
        func decode(_ name: String) throws -> TransportMessage {
            try self.macDecoder.decode(TransportMessage.self, from: Data(XCTUnwrap(messages[name]).utf8))
        }
        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: SendToMacProtocolAndroidExport.timestamp))
        let transcript = SendToMacProtocolAndroidExport.transcript

        guard case .hello(let hello) = try decode("hello") else { return XCTFail("hello") }
        XCTAssertTrue(hello.isProtocolVersionCompatible)
        XCTAssertEqual(hello.deviceName, SendToMacProtocolAndroidExport.deviceName)
        XCTAssertEqual(hello.deviceId, SendToMacProtocolAndroidExport.deviceID)
        XCTAssertTrue(ReleaseTrain.stable.acceptsPeer(hello.releaseTrain))

        guard case .authenticate(let pairing) = try decode("authenticatePairing") else { return XCTFail("auth") }
        XCTAssertEqual(pairing.pairingCode, SendToMacProtocolAndroidExport.pairingCode)
        XCTAssertEqual(pairing.timestamp, timestamp)
        guard case .authenticate(let later) = try decode("authenticateCredential") else { return XCTFail("auth") }
        XCTAssertEqual(later.pairingCode, "")

        guard case .sessionStart(let start) = try decode("sessionStart") else { return XCTFail("start") }
        XCTAssertEqual(start.sessionId, SendToMacProtocolAndroidExport.sessionID)
        XCTAssertEqual(start.model, SendToMacProtocolAndroidExport.model)
        XCTAssertEqual(start.language, "en-US")

        guard case .transcriptChunk(let chunk) = try decode("transcriptChunk") else { return XCTFail("chunk") }
        XCTAssertEqual(chunk.sessionId, SendToMacProtocolAndroidExport.sessionID)
        XCTAssertEqual(chunk.sequenceNumber, 1)
        XCTAssertEqual(chunk.text, transcript)
        XCTAssertTrue(chunk.isFinal)
        XCTAssertEqual(chunk.timestamp, timestamp)

        guard case .sessionEnd(let end) = try decode("sessionEnd") else { return XCTFail("end") }
        XCTAssertEqual(end.finalText, transcript)
        XCTAssertEqual(end.duration, 12.5)
        XCTAssertEqual(end.wordCount, transcript.split(whereSeparator: \.isWhitespace).count)

        guard case .pong = try decode("pong") else { return XCTFail("pong") }
    }

    // MARK: - Helpers

    /// What `TransportServerHandshake` and `acceptSecureSession` build from the phone's frames.
    private func macProof(for vector: SendToMacProtocolAndroidExport.Handshake) throws -> TransportPairingProof {
        let clientFrame = Data(vector.clientFrame.utf8)
        let share = try XCTUnwrap(TransportKeyShare.decode(clientFrame))
        let schedule = try TransportKeySchedule(
            localKey: Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: SendToMacProtocolAndroidExport.serverPrivateKey
            ),
            peerShare: share,
            clientFrame: clientFrame,
            serverFrame: Data(vector.serverFrame.utf8)
        )
        return TransportPairingProof(
            schedule: schedule,
            clientFinished: try self.bytes(vector.clientFinished),
            credentialID: share.credentialID,
            requestsCredential: share.requestsCredential == true
        )
    }

    /// The phone's keys after it has sealed "client finished".
    private func phoneKeys(
        for vector: SendToMacProtocolAndroidExport.Handshake,
        secret: TransportPairingSecret
    ) throws -> TransportSessionKeys {
        let serverFrame = Data(vector.serverFrame.utf8)
        let schedule = try TransportKeySchedule(
            localKey: Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: SendToMacProtocolAndroidExport.clientPrivateKey
            ),
            peerShare: XCTUnwrap(TransportKeyShare.decode(serverFrame)),
            clientFrame: Data(vector.clientFrame.utf8),
            serverFrame: serverFrame
        )
        var keys = schedule.sessionKeys(preSharedKey: TransportKeySchedule.preSharedKey(for: secret), role: .client)
        XCTAssertEqual(
            SendToMacProtocolAndroidExport.hex(try keys.outbound.seal(TransportKeySchedule.clientFinished)),
            vector.clientFinished
        )
        return keys
    }

    private func bytes(_ hex: String) throws -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(try XCTUnwrap(UInt8(hex[index ..< next], radix: 16)))
            index = next
        }
        return data
    }
}
