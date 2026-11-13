import Network
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Loopback proof that the Send to Mac channel is encrypted end to end (#1585):
/// a peer without the pairing key can neither read nor inject a transcript.
extension TransportLoopbackTests {
    // MARK: - Encryption

    func testPlaintextPeer_isRefusedAndCannotInjectATranscript() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)
        let inbox = TranscriptInbox()
        server.onTranscriptReceived = { sessionId, text in
            inbox.record(sessionId: sessionId, text: text)
        }

        // A protocol v1 phone, and a current one that skips encryption, both
        // hold the right code and still must not get a single frame through.
        for (version, reason) in [
            (1, "Protocol version mismatch"),
            (SpeakTransportProtocolVersion, "requires an encrypted connection")
        ] {
            let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
            defer { channel.close() }
            try await channel.start()
            try await channel.sendPlaintext(.hello(HelloMessage(
                protocolVersion: version, deviceName: "Plaintext Phone", deviceId: "plaintext-\(version)"
            )))
            let refusal = try await withHangGuard("refusal") { () -> String? in
                guard case .error(let error) = try await channel.receiveAnyMessage() else { return nil }
                return error.message
            }
            XCTAssertTrue(
                refusal?.contains(reason) == true,
                "Unhelpful refusal for v\(version): \(String(describing: refusal))"
            )
            let didClose = await self.waitForClosure(of: channel)
            XCTAssertTrue(didClose, "The Mac must hang up on a plaintext v\(version) peer")

            // Frames queued behind the hello can reset the socket before the
            // refusal arrives, so injection gets its own connection.
            let injector = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
            defer { injector.close() }
            try await injector.start()
            let code = PairingManager.shared.pairingCode
            _ = try? await injector.sendPlaintext(.hello(HelloMessage(
                protocolVersion: version, deviceName: "Plaintext Phone", deviceId: "plaintext-\(version)"
            )))
            _ = try? await injector.sendPlaintext(.authenticate(AuthenticateMessage(pairingCode: code)))
            _ = try? await injector.sendPlaintext(.transcriptChunk(TranscriptChunkMessage(
                sessionId: "plaintext", sequenceNumber: 1, text: "injected in plaintext", isFinal: true
            )))
            let injectorClosed = await self.waitForClosure(of: injector)
            XCTAssertTrue(injectorClosed, "The Mac must hang up on a plaintext v\(version) injector")
        }

        XCTAssertNil(inbox.text, "Plaintext text must never reach the Mac's insertion point")
        XCTAssertTrue(server.connectedDevices.isEmpty)
        XCTAssertTrue(PairingManager.shared.pairedDevices.isEmpty)
    }

    func testPeerWithoutThePairingKey_cannotCompleteTheHandshakeOrInject() async throws {
        let endpoint = try await self.startServer()
        let server = try XCTUnwrap(self.server)
        let inbox = TranscriptInbox()
        server.onTranscriptReceived = { sessionId, text in
            inbox.record(sessionId: sessionId, text: text)
        }

        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { channel.close() }
        try await channel.start()
        do {
            try await withHangGuard("handshake") { try await channel.establishSecureSession(pairingCode: "000000x") }
            XCTFail("A peer without the pairing key must not complete the handshake")
        } catch let rejection as TransportRejection {
            XCTAssertEqual(rejection.message, "Invalid pairing code")
        }

        let isEncrypted = await channel.isEncrypted
        XCTAssertFalse(isEncrypted, "A refused handshake must not leave usable keys behind")
        let chunk = TranscriptChunkMessage(sessionId: "s", sequenceNumber: 1, text: "injected", isFinal: true)
        do {
            try await channel.send(.transcriptChunk(chunk))
            XCTFail("A channel without session keys must refuse to send")
        } catch {
            XCTAssertEqual(error as? TransportSecurityError, .notEncrypted)
        }
        let didClose = await self.waitForClosure(of: channel)
        XCTAssertTrue(didClose)
        XCTAssertNil(inbox.text)
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    func testWrongCodesThroughTheEncryptedHandshake_stillHitTheAttemptLimit() async throws {
        let endpoint = try await self.startServer()

        for _ in 0..<PairingAttemptLimiter.freeFailures {
            let client = MacConnection()
            await client.connect(to: endpoint, named: "Test Mac", pairingCode: "wrong")
            XCTAssertEqual(client.state, .error("Invalid pairing code"))
        }

        // Even the right code is refused during the lockout, without being checked.
        let client = MacConnection()
        await client.connect(to: endpoint, named: "Test Mac", pairingCode: PairingManager.shared.pairingCode)
        guard case .error(let message) = client.state else {
            XCTFail("Expected a lockout, got \(client.state)")
            return
        }
        XCTAssertTrue(message.contains("Too many failed pairing attempts"), "Unexpected refusal: \(message)")
    }

    // MARK: - Device credentials (#1643)

    func testReconnect_usesTheIssuedCredentialAndNeverFallsBackToTheCode() async throws {
        let endpoint = try await self.startServer()
        let store = InMemoryTransportCredentialStore()

        let first = MacConnection(credentialStore: store)
        await first.connect(to: endpoint, named: "Test Mac", pairingCode: PairingManager.shared.pairingCode)
        XCTAssertEqual(first.state, .connected)
        first.disconnect()
        let credential = try XCTUnwrap(store.credential(forMac: "Test Mac"), "Pairing must store a credential")
        XCTAssertTrue(PairingManager.shared.hasCredential(credential.id))

        // The code is ignored once a credential exists, so a wrong one still connects.
        let second = MacConnection(credentialStore: store)
        await second.connect(to: endpoint, named: "Test Mac", pairingCode: "ignored")
        XCTAssertEqual(second.state, .connected)
        second.disconnect()

        // Regenerating the code revokes the credential, and the phone does not
        // quietly retry with the code it was given.
        let newCode = PairingManager.shared.regeneratePairingCode()
        let third = MacConnection(credentialStore: store)
        await third.connect(to: endpoint, named: "Test Mac", pairingCode: newCode)
        XCTAssertEqual(third.state, .error(TransportChannel.revokedCredentialMessage))
        XCTAssertEqual(store.credential(forMac: "Test Mac"), credential, "Only the user may forget the Mac")

        third.forgetMac(named: "Test Mac")
        await third.connect(to: endpoint, named: "Test Mac", pairingCode: newCode)
        XCTAssertEqual(third.state, .connected)
        XCTAssertNotEqual(store.credential(forMac: "Test Mac"), credential)
        third.disconnect()
    }
}
