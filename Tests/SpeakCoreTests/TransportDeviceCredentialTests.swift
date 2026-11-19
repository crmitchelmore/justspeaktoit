import CryptoKit
import XCTest

@testable import SpeakCore

/// Device credentials that replace the six-digit code after the first pairing,
/// so a device impersonating the Mac has nothing to guess offline (#1643).
final class TransportDeviceCredentialTests: XCTestCase {
    private var manager: PairingManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suite = "TransportDeviceCredentialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        self.manager = PairingManager(defaults: defaults)
    }

    private struct Outcome {
        let result: PairingAttemptResult
        let issued: TransportDeviceCredential?
        /// The phone's "client finished" frame, as an impostor Mac would capture it.
        let clientFinished: Data
        let server: TransportServerHandshake
    }

    /// Runs one handshake against `manager`, as `TransportChannel` would.
    private func handshake(_ secret: TransportPairingSecret) throws -> Outcome {
        let client = try TransportClientHandshake(secret: secret)
        let server = try TransportServerHandshake(clientFrame: client.frame)
        let finish = try client.finish(serverFrame: server.frame)
        let proof = TransportPairingProof(
            schedule: server.schedule,
            clientFinished: finish.finished,
            credentialID: server.clientShare.credentialID,
            requestsCredential: server.clientShare.requestsCredential == true
        )
        let result = self.manager.authorize(proof)
        var issued: TransportDeviceCredential?
        if result == .accepted {
            var serverKeys = try XCTUnwrap(proof.acceptedKeys)
            var clientKeys = finish.keys
            let sealed = try serverKeys.outbound.seal(
                TransportKeySchedule.serverFinished(issuing: proof.issuedCredential)
            )
            issued = try TransportKeySchedule.credential(inServerFinished: try clientKeys.inbound.open(sealed))
            XCTAssertEqual(issued, proof.issuedCredential)
        }
        return Outcome(result: result, issued: issued, clientFinished: finish.finished, server: server)
    }

    func testCodePairing_issuesACredentialThatLaterSessionsUseInPlaceOfTheCode() throws {
        let first = try self.handshake(.code(self.manager.pairingCode))
        XCTAssertEqual(first.result, .accepted)
        let credential = try XCTUnwrap(first.issued, "Pairing with the code must issue a credential")
        XCTAssertEqual(credential.secret.count, 32)
        XCTAssertTrue(self.manager.hasCredential(credential.id))

        let later = try self.handshake(.credential(credential))
        XCTAssertEqual(later.result, .accepted)
        XCTAssertNil(later.issued, "A credential session must not be issued another credential")
        XCTAssertEqual(later.server.clientShare.credentialID, credential.id)
        XCTAssertNil(later.server.clientShare.requestsCredential)
    }

    func testImpostorMac_cannotTestCodesAgainstACredentialSession() throws {
        let code = self.manager.pairingCode
        let credential = try XCTUnwrap(try self.handshake(.code(code)).issued)
        let captured = try self.handshake(.credential(credential))

        // Even the right code, the impostor's best possible guess, opens nothing.
        var guessed = captured.server.schedule.sessionKeys(pairingCode: code, role: .server)
        XCTAssertThrowsError(try guessed.inbound.open(captured.clientFinished))
        let proof = TransportPairingProof(
            schedule: captured.server.schedule,
            clientFinished: captured.clientFinished,
            credentialID: credential.id
        )
        XCTAssertFalse(proof.verifies(pairingCode: code))
        XCTAssertFalse(proof.verifies(credential: .generate()))
        XCTAssertTrue(proof.verifies(credential: credential))
    }

    func testRegeneratedCodeAndRemovedDevice_revokeCredentialsWithoutCountingAttempts() throws {
        let credential = try XCTUnwrap(try self.handshake(.code(self.manager.pairingCode)).issued)
        self.manager.bindCredential(credential.id, toDevice: "phone-1")
        self.manager.removePairedDevice(id: "phone-1")
        XCTAssertFalse(self.manager.hasCredential(credential.id))

        // Far more refusals than the free budget still never lock out the code.
        for _ in 0...PairingAttemptLimiter.freeFailures * 2 {
            XCTAssertEqual(try self.handshake(.credential(credential)).result, .rejected)
        }
        let replacement = try XCTUnwrap(try self.handshake(.code(self.manager.pairingCode)).issued)
        _ = self.manager.regeneratePairingCode()
        XCTAssertEqual(try self.handshake(.credential(replacement)).result, .rejected)
    }

    func testWrongCode_issuesNoCredential() throws {
        let outcome = try self.handshake(.code("not-the-code"))
        XCTAssertEqual(outcome.result, .rejected)
        XCTAssertNil(outcome.issued)
    }

    func testCredentialStore_keepsOnlyTheNewestCredentials() throws {
        var issued: [TransportDeviceCredential] = []
        for _ in 0...PairingManager.maximumCredentials {
            issued.append(try XCTUnwrap(try self.handshake(.code(self.manager.pairingCode)).issued))
        }
        XCTAssertFalse(self.manager.hasCredential(issued[0].id))
        XCTAssertTrue(self.manager.hasCredential(try XCTUnwrap(issued.last).id))
    }

    func testServerFinished_acceptsOnlyTheMarkerOrTheMarkerAndOneCredential() throws {
        XCTAssertNil(try TransportKeySchedule.credential(inServerFinished: TransportKeySchedule.serverFinished))
        let credential = TransportDeviceCredential.generate()
        let finished = TransportKeySchedule.serverFinished(issuing: credential)
        XCTAssertEqual(try TransportKeySchedule.credential(inServerFinished: finished), credential)
        XCTAssertThrowsError(
            try TransportKeySchedule.credential(inServerFinished: TransportKeySchedule.serverFinished + Data([1]))
        )
        XCTAssertThrowsError(try TransportKeySchedule.credential(inServerFinished: Data("other".utf8)))
    }

    func testLegacyKeyShare_omitsTheCredentialFields() throws {
        let legacy = try TransportClientHandshake()
        let text = try XCTUnwrap(String(data: legacy.frame, encoding: .utf8))
        XCTAssertFalse(text.contains("credentialID"))
        XCTAssertFalse(text.contains("requestsCredential"))
        let pairing = try TransportClientHandshake(secret: .code("123456"))
        XCTAssertEqual(TransportKeyShare.decode(pairing.frame)?.requestsCredential, true)
    }
}
