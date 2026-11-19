import Foundation
@testable import SpeakCore
import XCTest

/// Drives the shared Windows/Linux receiver through pairing, credential
/// re-authentication, refusals and transcript delivery without a socket.
final class TransportReceiverSessionTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func testPairingWithCode_issuesCredentialAcksAndDeliversFinalTextOnly() throws {
        let store = TransportReceiverPairingStore()
        let session = TransportReceiverSession(pairing: store)
        var phone = try handshake(session, secret: .code(store.pairingCode))
        let credential = try XCTUnwrap(phone.issued)

        XCTAssertTrue(try exchange(session, &phone, hello()).isEmpty)
        let auth = try exchange(session, &phone, .authenticate(AuthenticateMessage(pairingCode: store.pairingCode)))
        guard case .authResult(let result)? = auth.first else { return XCTFail("expected auth result, got \(auth)") }
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.sessionToken)
        XCTAssertEqual(phone.events, [.paired(deviceID: "phone-1", deviceName: "Test iPhone")])
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(session.frameLimit, .session)
        XCTAssertEqual(store.pairedDevices.map(\.name), ["Test iPhone"])

        _ = try exchange(session, &phone, .sessionStart(SessionStartMessage(sessionId: "s1", model: "m")))
        XCTAssertEqual(session.currentSessionID, "s1")
        let partial = try exchange(session, &phone, chunk(1, "hel", isFinal: false))
        let final = try exchange(session, &phone, chunk(2, "hello there", isFinal: true))
        guard case .ack(let partialAck)? = partial.first, case .ack(let finalAck)? = final.first else {
            return XCTFail("expected acks")
        }
        XCTAssertEqual([partialAck.sequenceNumber, finalAck.sequenceNumber], [1, 2])
        XCTAssertEqual(phone.events.last, .deliver(sessionID: "s1", text: "hello there"))
        XCTAssertEqual(phone.events.filter { if case .deliver = $0 { true } else { false } }.count, 1)
        guard case .pong? = try exchange(session, &phone, .ping).first else { return XCTFail("expected pong") }

        // The issued credential authenticates a later session without the code.
        let later = TransportReceiverSession(pairing: store)
        var returning = try handshake(later, secret: .credential(credential))
        XCTAssertNil(returning.issued)
        _ = try exchange(later, &returning, hello())
        guard case .authResult(let laterResult)? = try exchange(
            later, &returning, .authenticate(AuthenticateMessage(pairingCode: ""))
        ).first else { return XCTFail("expected auth result") }
        XCTAssertTrue(laterResult.success)
    }

    func testWrongCode_isRefusedInPlaintextThenLocksOut() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = TransportReceiverPairingStore()
        let code = store.pairingCode
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<5 {
            let session = TransportReceiverSession(pairing: store, now: { clock })
            XCTAssertEqual(try refusal(session, secret: .code(wrong)), "Invalid pairing code")
        }
        let locked = TransportReceiverSession(pairing: store, now: { clock })
        XCTAssertEqual(try refusal(locked, secret: .code(code)),
                       "Too many failed pairing attempts. Try again in 30 seconds.")
        clock.addTimeInterval(31)
        let session = TransportReceiverSession(pairing: store, now: { clock })
        XCTAssertNotNil(try handshake(session, secret: .code(code)).issued)
    }

    func testForgottenDevice_credentialIsRevoked() throws {
        let store = TransportReceiverPairingStore()
        let session = TransportReceiverSession(pairing: store)
        var phone = try handshake(session, secret: .code(store.pairingCode))
        _ = try exchange(session, &phone, hello())
        _ = try exchange(session, &phone, .authenticate(AuthenticateMessage(pairingCode: store.pairingCode)))
        let credential = try XCTUnwrap(phone.issued)
        XCTAssertTrue(store.hasCredential(credential.id))

        store.removePairedDevice(id: "phone-1")
        XCTAssertFalse(store.hasCredential(credential.id))
        XCTAssertEqual(try refusal(TransportReceiverSession(pairing: store), secret: .credential(credential)),
                       TransportReceiverWording.desktop.revokedCredential)

        store.regeneratePairingCode()
        XCTAssertTrue(store.pairedDevices.isEmpty)
    }

    func testPlaintextPeers_areRefused() throws {
        let v1Hello = try encoder.encode(TransportMessage.hello(HelloMessage(
            protocolVersion: 1, deviceName: "Old", deviceId: "old", releaseTrain: nil
        )))
        let legacy = TransportReceiverSession(pairing: TransportReceiverPairingStore())
        guard case .error(let mismatch) = try plaintextReply(legacy.receive(v1Hello)) else {
            return XCTFail("expected a version error")
        }
        XCTAssertEqual(mismatch.code, 400)
        XCTAssertTrue(legacy.isClosed)

        let v2Hello = try encoder.encode(hello())
        let plaintextV2 = TransportReceiverSession(pairing: TransportReceiverPairingStore())
        guard case .error(let upgrade) = try plaintextReply(plaintextV2.receive(v2Hello)) else {
            return XCTFail("expected an upgrade-required error")
        }
        XCTAssertEqual(upgrade.code, 426)

        let garbage = TransportReceiverSession(pairing: TransportReceiverPairingStore())
        XCTAssertEqual(garbage.receive(Data("nonsense".utf8)), [.close])
        let oversized = TransportReceiverSession(pairing: TransportReceiverPairingStore())
        XCTAssertEqual(oversized.receive(Data(count: TransportFrameLimit.handshake.maximumBytes + 1)), [.close])
    }

    func testMessagesBeforeAuthentication_closeTheConnection() throws {
        let store = TransportReceiverPairingStore()
        let session = TransportReceiverSession(pairing: store)
        var phone = try handshake(session, secret: .code(store.pairingCode))
        let sealed = try phone.keys.outbound.seal(try encoder.encode(chunk(1, "sneaky", isFinal: true)))
        let actions = session.receive(sealed)
        XCTAssertEqual(actions, [.close])
        XCTAssertTrue(store.pairedDevices.isEmpty)
    }

    func testReleaseTrainMismatch_isRefused() throws {
        let store = TransportReceiverPairingStore()
        let session = TransportReceiverSession(pairing: store, releaseTrain: .alpha)
        var phone = try handshake(session, secret: .code(store.pairingCode))
        let reply = try exchange(session, &phone, hello(train: .stable))
        guard case .error(let error)? = reply.first else { return XCTFail("expected error, got \(reply)") }
        XCTAssertEqual(error.message, "Release train mismatch")
        XCTAssertTrue(session.isClosed)
    }

    func testTamperedFrame_closesTheConnection() throws {
        let store = TransportReceiverPairingStore()
        let session = TransportReceiverSession(pairing: store)
        var phone = try handshake(session, secret: .code(store.pairingCode))
        var sealed = try phone.keys.outbound.seal(try encoder.encode(TransportMessage.ping))
        sealed[sealed.startIndex] ^= 1
        XCTAssertEqual(session.receive(sealed), [.close])
    }

    func testPairingStore_persistsAndRestoresState() throws {
        let saved = LockedBox<TransportReceiverPairingState?>(nil)
        let store = TransportReceiverPairingStore(persist: { saved.value = $0 })
        let code = store.pairingCode
        let decision = store.authorize(
            credentialID: nil, requestsCredential: true, now: Date(),
            verifyCode: { $0 == code }, verifyCredential: { _ in false }
        )
        let issued = try XCTUnwrap(decision.issued)
        store.addPairedDevice(id: "d", name: "Phone", credentialID: issued.id)
        let state = try XCTUnwrap(saved.value)
        let restored = TransportReceiverPairingStore(
            state: try decoder.decode(TransportReceiverPairingState.self, from: try encoder.encode(state))
        )
        XCTAssertEqual(restored.pairingCode, code)
        XCTAssertTrue(restored.hasCredential(issued.id))
        XCTAssertEqual(restored.pairedDevices.map(\.id), ["d"])
    }

    #if canImport(CryptoKit) && !SPEAK_PORTABLE_CORE
    /// The shipping iPhone sender's CryptoKit handshake against the portable receiver.
    func testCryptoKitPhone_pairsWithPortableReceiver() throws {
        let store = TransportReceiverPairingStore()
        let session = TransportReceiverSession(pairing: store)
        let client = try TransportClientHandshake(secret: .code(store.pairingCode), requestsCredential: true)
        let serverFrame = try XCTUnwrap(sentFrames(session.receive(client.frame)).first)
        var finish = try client.finish(serverFrame: serverFrame)
        let confirmation = try XCTUnwrap(sentFrames(session.receive(finish.finished)).first)
        let credential = try XCTUnwrap(
            try TransportKeySchedule.credential(inServerFinished: try finish.keys.inbound.open(confirmation))
        )

        for message in [hello(), .authenticate(AuthenticateMessage(pairingCode: store.pairingCode))] {
            let sealed = try finish.keys.outbound.seal(try encoder.encode(message))
            for frame in sentFrames(session.receive(sealed)) {
                let reply = try decoder.decode(TransportMessage.self, from: try finish.keys.inbound.open(frame))
                if case .authResult(let result) = reply { XCTAssertTrue(result.success) }
            }
        }
        XCTAssertTrue(session.isAuthenticated)

        let again = TransportReceiverSession(pairing: store)
        let returning = try TransportClientHandshake(secret: .credential(credential), requestsCredential: true)
        let reply = try XCTUnwrap(sentFrames(again.receive(returning.frame)).first)
        var resumed = try returning.finish(serverFrame: reply)
        let opened = try resumed.keys.inbound.open(try XCTUnwrap(sentFrames(again.receive(resumed.finished)).first))
        XCTAssertNil(try TransportKeySchedule.credential(inServerFinished: opened))
    }
    #endif

    // MARK: - Phone driver

    private struct Phone {
        var keys: TransportPortableSessionKeys
        var issued: TransportDeviceCredential?
        var events: [TransportReceiverAction] = []
    }

    private func handshake(_ session: TransportReceiverSession, secret: TransportPairingSecret) throws -> Phone {
        let client = try TransportPortableClientHandshake(secret: secret)
        let serverFrame = try XCTUnwrap(sentFrames(session.receive(client.frame)).first)
        var finish = try client.finish(serverFrame: serverFrame)
        let confirmation = try XCTUnwrap(sentFrames(session.receive(finish.finished)).first)
        let opened = try finish.keys.inbound.open(confirmation)
        let issued = try TransportHandshakeLabel.credential(inServerFinished: opened)
        return Phone(keys: finish.keys, issued: issued)
    }

    /// The plaintext refusal the receiver sends instead of "server finished".
    private func refusal(_ session: TransportReceiverSession, secret: TransportPairingSecret) throws -> String? {
        let client = try TransportPortableClientHandshake(secret: secret)
        let serverFrame = try XCTUnwrap(sentFrames(session.receive(client.frame)).first)
        let finish = try client.finish(serverFrame: serverFrame)
        guard case .authResult(let result) = try plaintextReply(session.receive(finish.finished)) else { return nil }
        XCTAssertFalse(result.success)
        XCTAssertTrue(session.isClosed)
        return result.errorMessage
    }

    private func exchange(
        _ session: TransportReceiverSession, _ phone: inout Phone, _ message: TransportMessage
    ) throws -> [TransportMessage] {
        let actions = session.receive(try phone.keys.outbound.seal(try encoder.encode(message)))
        var replies: [TransportMessage] = []
        for action in actions {
            if case .send(let frame) = action {
                replies.append(try decoder.decode(TransportMessage.self, from: try phone.keys.inbound.open(frame)))
            } else if action != .close {
                phone.events.append(action)
            }
        }
        return replies
    }

    private func plaintextReply(_ actions: [TransportReceiverAction]) throws -> TransportMessage {
        XCTAssertEqual(actions.last, .close)
        return try decoder.decode(TransportMessage.self, from: try XCTUnwrap(sentFrames(actions).first))
    }

    private func sentFrames(_ actions: [TransportReceiverAction]) -> [Data] {
        actions.compactMap { action in
            if case .send(let frame) = action { return frame }
            return nil
        }
    }

    private func hello(train: ReleaseTrain = .current) -> TransportMessage {
        .hello(HelloMessage(deviceName: "Test iPhone", deviceId: "phone-1", releaseTrain: train))
    }

    private func chunk(_ sequence: Int, _ text: String, isFinal: Bool) -> TransportMessage {
        .transcriptChunk(
            TranscriptChunkMessage(sessionId: "s1", sequenceNumber: sequence, text: text, isFinal: isFinal)
        )
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
