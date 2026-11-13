import CryptoKit
import Network
import XCTest

@testable import SpeakCore

/// The encrypted Send to Mac handshake and framing (protocol v2, issue #1585),
/// exercised without a network so every byte on the "wire" is visible.
final class TransportSecureSessionTests: XCTestCase {
    private let code = "482916"
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private struct Session {
        var client: TransportSessionKeys
        var server: TransportSessionKeys
        /// Every frame that crossed the wire during the handshake, in order.
        let wire: [Data]
    }

    private func handshake(clientCode: String, serverCode: String) throws -> (Session?, wire: [Data]) {
        let client = try TransportClientHandshake()
        let server = try TransportServerHandshake(clientFrame: client.frame)
        let finish = try client.finish(serverFrame: server.frame, pairingCode: clientCode)
        let proof = TransportPairingProof(schedule: server.schedule, clientFinished: finish.finished)
        let wire = [client.frame, server.frame, finish.finished]
        guard proof.verifies(pairingCode: serverCode), var serverKeys = proof.acceptedKeys else {
            return (nil, wire)
        }
        let serverFinished = try serverKeys.outbound.seal(TransportKeySchedule.serverFinished)
        var clientKeys = finish.keys
        XCTAssertEqual(try clientKeys.inbound.open(serverFinished), TransportKeySchedule.serverFinished)
        return (Session(client: clientKeys, server: serverKeys, wire: wire + [serverFinished]), wire + [serverFinished])
    }

    private func pairedSession() throws -> Session {
        try XCTUnwrap(try self.handshake(clientCode: self.code, serverCode: self.code).0)
    }

    private func transcriptFrame(_ text: String) throws -> Data {
        try self.encoder.encode(TransportMessage.transcriptChunk(
            TranscriptChunkMessage(sessionId: "session-1", sequenceNumber: 1, text: text, isFinal: true)
        ))
    }

    // MARK: - Paired peers

    func testPairedPeers_roundTripTranscriptsInBothDirections() throws {
        var session = try self.pairedSession()
        let message = try self.transcriptFrame("Hello Mac")

        let sealed = try session.client.outbound.seal(message)
        XCTAssertEqual(try session.server.inbound.open(sealed), message)

        let ack = try self.encoder.encode(TransportMessage.ack(AckMessage(sequenceNumber: 1)))
        XCTAssertEqual(try session.client.inbound.open(try session.server.outbound.seal(ack)), ack)

        let second = try self.transcriptFrame("Second line")
        XCTAssertEqual(try session.server.inbound.open(try session.client.outbound.seal(second)), second)
    }

    // MARK: - Reading

    func testEavesdropper_seesNoTranscriptTextAndCannotDecryptEvenWithTheCode() throws {
        var session = try self.pairedSession()
        let sealed = try session.client.outbound.seal(try self.transcriptFrame("my secret dictation"))

        for frame in session.wire + [sealed] {
            XCTAssertNil(frame.range(of: Data("my secret dictation".utf8)))
            XCTAssertNil(frame.range(of: Data(self.code.utf8)), "The pairing code must never cross the wire")
        }

        // A passive observer who later learns the code still lacks either
        // side's ephemeral private key, so it cannot rebuild the session keys.
        let clientShare = try XCTUnwrap(TransportKeyShare.decode(session.wire[0]))
        let observer = try TransportKeySchedule(
            localKey: Curve25519.KeyAgreement.PrivateKey(),
            peerShare: clientShare,
            clientFrame: session.wire[0],
            serverFrame: session.wire[1]
        )
        var guessed = observer.sessionKeys(pairingCode: self.code, role: .server)
        XCTAssertThrowsError(try guessed.inbound.open(session.wire[2]))
        XCTAssertThrowsError(try guessed.inbound.open(sealed))
    }

    func testMacWithADifferentCode_cannotReadThePhonesFrames() throws {
        let client = try TransportClientHandshake()
        let server = try TransportServerHandshake(clientFrame: client.frame)
        var finish = try client.finish(serverFrame: server.frame, pairingCode: self.code)
        let sealed = try finish.keys.outbound.seal(try self.transcriptFrame("for the right Mac only"))

        var wrongKeys = server.schedule.sessionKeys(pairingCode: "000000", role: .server)
        XCTAssertThrowsError(try wrongKeys.inbound.open(finish.finished))
        XCTAssertThrowsError(try wrongKeys.inbound.open(sealed))
        XCTAssertFalse(
            TransportPairingProof(schedule: server.schedule, clientFinished: finish.finished)
                .verifies(pairingCode: "000000")
        )
    }

    // MARK: - Injection

    func testPeerWithoutThePairingKey_failsTheProofAndCannotInject() throws {
        let (session, wire) = try self.handshake(clientCode: "111111", serverCode: self.code)
        XCTAssertNil(session, "The Mac must not accept a proof sealed with another code")

        // Whatever the impostor seals next is just as unreadable to the Mac.
        let client = try TransportClientHandshake()
        let server = try TransportServerHandshake(clientFrame: client.frame)
        var impostor = try client.finish(serverFrame: server.frame, pairingCode: "111111")
        let forged = try impostor.keys.outbound.seal(try self.transcriptFrame("injected"))
        var macKeys = server.schedule.sessionKeys(pairingCode: self.code, role: .server)
        XCTAssertThrowsError(try macKeys.inbound.open(impostor.finished))
        XCTAssertThrowsError(try macKeys.inbound.open(forged))
        XCTAssertEqual(wire.count, 3, "A failed proof gets no server-finished frame to test guesses against")
    }

    func testTamperedReplayedAndReorderedFrames_areRejected() throws {
        var session = try self.pairedSession()
        let first = try session.client.outbound.seal(try self.transcriptFrame("one"))
        let second = try session.client.outbound.seal(try self.transcriptFrame("two"))

        var tampered = first
        tampered[0] ^= 0x01
        var reader = session.server.inbound
        XCTAssertThrowsError(try reader.open(tampered))
        XCTAssertThrowsError(try reader.open(second), "Frames must open in the order they were sealed")

        XCTAssertNoThrow(try session.server.inbound.open(first))
        XCTAssertThrowsError(try session.server.inbound.open(first), "A replayed frame must not open twice")
        XCTAssertNoThrow(try session.server.inbound.open(second))

        // A frame sealed for the other direction cannot be reflected back.
        let reflected = try session.client.outbound.seal(try self.transcriptFrame("reflected"))
        XCTAssertThrowsError(try session.client.inbound.open(reflected))
    }

    func testFramesFromAnotherSession_cannotBeReplayed() throws {
        var earlier = try self.pairedSession()
        var later = try self.pairedSession()
        let captured = try earlier.client.outbound.seal(try self.transcriptFrame("yesterday"))
        XCTAssertThrowsError(try later.server.inbound.open(captured))
    }

    // MARK: - Handshake refusals

    func testServerRefusesPlaintextAndMismatchedHandshakes() throws {
        let plaintextHello = try self.encoder.encode(
            TransportMessage.hello(HelloMessage(protocolVersion: 1, deviceName: "Old", deviceId: "old"))
        )
        XCTAssertThrowsError(try TransportServerHandshake(clientFrame: plaintextHello)) { error in
            XCTAssertEqual(error as? TransportServerHandshake.Refusal, .plaintextHello(protocolVersion: 1))
        }

        let future = try TransportClientHandshake(protocolVersion: SpeakTransportProtocolVersion + 1)
        XCTAssertThrowsError(try TransportServerHandshake(clientFrame: future.frame)) { error in
            XCTAssertEqual(
                error as? TransportServerHandshake.Refusal,
                .versionMismatch(protocolVersion: SpeakTransportProtocolVersion + 1)
            )
        }

        // An all-zero key is a low-order point whose shared secret is predictable.
        let lowOrder = try TransportKeyShare(
            protocolVersion: SpeakTransportProtocolVersion, keyShare: Data(count: 32)
        ).encoded()
        XCTAssertThrowsError(try TransportServerHandshake(clientFrame: lowOrder))
        XCTAssertThrowsError(try TransportServerHandshake(clientFrame: Data("garbage".utf8)))
    }

    // MARK: - Pairing limit

    func testProofAttempts_countTowardsTheLockoutAndAreNotCheckedDuringIt() throws {
        let suite = "TransportSecureSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let manager = PairingManager(defaults: defaults)
        let now = Date()

        for _ in 0..<PairingAttemptLimiter.freeFailures {
            XCTAssertEqual(manager.attemptPairing(now: now) { _ in false }, .rejected)
        }
        var wasChecked = false
        let result = manager.attemptPairing(now: now) { _ in
            wasChecked = true
            return true
        }
        guard case .lockedOut = result else {
            XCTFail("Expected a lockout, got \(result)")
            return
        }
        XCTAssertFalse(wasChecked, "A proof must not be checked during a lockout")
    }

    // MARK: - Channel

    func testChannel_refusesToSendOrReceiveBeforeTheHandshake() async throws {
        let endpoint = try XCTUnwrap(SpeakTransportWire.endpoint(host: "127.0.0.1", port: 1))
        let channel = TransportChannel.connecting(to: endpoint, includesPeerToPeer: false)
        defer { channel.close() }

        do {
            try await channel.send(.ping)
            XCTFail("A message must not leave in plaintext")
        } catch {
            XCTAssertEqual(error as? TransportSecurityError, .notEncrypted)
        }
        do {
            _ = try await channel.receive()
            XCTFail("A plaintext message must not be accepted")
        } catch {
            XCTAssertEqual(error as? TransportSecurityError, .notEncrypted)
        }
    }
}
