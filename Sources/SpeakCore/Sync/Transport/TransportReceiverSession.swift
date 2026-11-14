import Foundation

// MARK: - Receiver session
//
// A transport-free receiver for one phone connection, shared by the Windows
// and Linux receivers. It follows the Mac's `TransportChannel.acceptSecureSession`
// and `TransportConnection` exactly: a plaintext key share per side, the sealed
// pairing proof, then sealed hello, authenticate, session and transcript
// messages. The caller feeds it every binary WebSocket message and carries out
// the actions it returns, in order.

/// Words the phone shows when a receiver refuses it.
package struct TransportReceiverWording: Sendable {
    package let encryptionRequired: String
    package let revokedCredential: String

    package static let mac = TransportReceiverWording(
        encryptionRequired: "Send to Mac requires an encrypted connection",
        revokedCredential: "This device is no longer paired with this Mac. Pair again with the code shown on the Mac."
    )

    package static let desktop = TransportReceiverWording(
        encryptionRequired: "Sending to this computer requires an encrypted connection",
        revokedCredential: "This device is no longer paired with this computer. "
            + "Pair again with the code shown in Just Speak to It's settings on the computer."
    )

    /// The plaintext refusal for a failed pairing proof; nil when it succeeded.
    package func refusal(for result: PairingAttemptResult, usedCredential: Bool) -> String? {
        switch result {
        case .accepted: nil
        case .rejected where usedCredential: revokedCredential
        case .rejected: "Invalid pairing code"
        case .lockedOut(let retryAfter):
            "Too many failed pairing attempts. Try again in \(Int(retryAfter.rounded(.up))) seconds."
        }
    }
}

package enum TransportReceiverAction: Equatable, Sendable {
    /// Send this frame as one binary WebSocket message.
    case send(Data)
    /// A paired phone finished a transcript; insert it at the cursor.
    case deliver(sessionID: String, text: String)
    /// A phone proved the code or its credential and said who it is.
    case paired(deviceID: String, deviceName: String)
    /// Close the connection after sending everything before this.
    case close
}

/// One phone connection's protocol state. Not thread-safe: one connection owns it.
package final class TransportReceiverSession {
    private enum Phase {
        case awaitingKeyShare
        case awaitingProof(TransportPortableServerHandshake)
        case encrypted(TransportPortableSessionKeys)
        case closed
    }

    private let pairing: TransportReceiverPairingStore
    private let wording: TransportReceiverWording
    private let protocolVersion: Int
    private let releaseTrain: ReleaseTrain
    private let now: () -> Date
    private let privateKey: [UInt8]?
    private var phase = Phase.awaitingKeyShare
    private var credentialID: UUID?
    private var usedCredential = false
    private var device: (id: String, name: String)?
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

    /// Frames above this close the connection; it rises once the phone authenticates.
    package private(set) var frameLimit = TransportFrameLimit.handshake
    package private(set) var isAuthenticated = false
    package private(set) var currentSessionID: String?

    package init(
        pairing: TransportReceiverPairingStore, wording: TransportReceiverWording = .desktop,
        protocolVersion: Int = SpeakTransportProtocolVersion, releaseTrain: ReleaseTrain = .current,
        now: @escaping () -> Date = { Date() }, privateKey: [UInt8]? = nil
    ) {
        self.pairing = pairing
        self.wording = wording
        self.protocolVersion = protocolVersion
        self.releaseTrain = releaseTrain
        self.now = now
        self.privateKey = privateKey
    }

    package var isClosed: Bool {
        if case .closed = phase { return true }
        return false
    }

    /// Handles one inbound binary message and returns what to do, in order.
    package func receive(_ frame: Data) -> [TransportReceiverAction] {
        guard frameLimit.admits(byteCount: frame.count) else { return close() }
        switch phase {
        case .awaitingKeyShare: return acceptKeyShare(frame)
        case .awaitingProof(let handshake): return checkProof(frame, handshake: handshake)
        case .encrypted(var keys):
            let message: TransportMessage
            do {
                let plaintext = try keys.inbound.open(frame)
                message = try decoder.decode(TransportMessage.self, from: plaintext)
            } catch { return close() }
            phase = .encrypted(keys)
            return handle(message)
        case .closed: return [.close]
        }
    }

    private func close() -> [TransportReceiverAction] {
        phase = .closed
        return [.close]
    }

    private func plaintext(_ message: TransportMessage) -> [TransportReceiverAction] {
        guard let data = try? encoder.encode(message) else { return close() }
        phase = .closed
        return [.send(data), .close]
    }

    private func acceptKeyShare(_ frame: Data) -> [TransportReceiverAction] {
        do {
            let handshake = try TransportPortableServerHandshake(
                clientFrame: frame, protocolVersion: protocolVersion, privateKey: privateKey
            )
            phase = .awaitingProof(handshake)
            return [.send(handshake.frame)]
        } catch let refusal as TransportHandshakeRefusal {
            guard let reply = refusal.reply(serverVersion: protocolVersion, wording: wording) else { return close() }
            return plaintext(.error(reply))
        } catch {
            return close()
        }
    }

    private func checkProof(_ frame: Data, handshake: TransportPortableServerHandshake) -> [TransportReceiverAction] {
        let share = handshake.clientShare
        var verified: TransportPortableSessionKeys?
        func verifies(_ preSharedKey: [UInt8]) -> Bool {
            var keys = handshake.schedule.sessionKeys(preSharedKey: preSharedKey, role: .server)
            guard let opened = try? keys.inbound.open(frame), opened == TransportHandshakeLabel.clientFinished else {
                return false
            }
            verified = keys
            return true
        }
        let decision = pairing.authorize(
            credentialID: share.credentialID,
            requestsCredential: share.credentialID == nil && share.requestsCredential == true,
            now: now(),
            verifyCode: { verifies(TransportPortableKeySchedule.pairingKey(for: $0)) },
            verifyCredential: { verifies(TransportPortableKeySchedule.credentialKey(for: $0.secret)) }
        )
        if let message = wording.refusal(for: decision.result, usedCredential: share.credentialID != nil) {
            return plaintext(.authResult(AuthResultMessage(
                success: false, errorMessage: message, releaseTrain: releaseTrain
            )))
        }
        guard var keys = verified,
              let finished = try? keys.outbound.seal(
                  TransportHandshakeLabel.serverFinished(issuing: decision.issued)
              ) else { return close() }
        phase = .encrypted(keys)
        credentialID = share.credentialID ?? decision.issued?.id
        usedCredential = share.credentialID != nil
        return [.send(finished)]
    }

    private func seal(_ message: TransportMessage) -> TransportReceiverAction? {
        guard case .encrypted(var keys) = phase, let data = try? encoder.encode(message),
              let sealed = try? keys.outbound.seal(data) else { return nil }
        phase = .encrypted(keys)
        return .send(sealed)
    }

    private func sealedThenClose(_ message: TransportMessage) -> [TransportReceiverAction] {
        let reply = seal(message)
        return (reply.map { [$0] } ?? []) + close()
    }

    private func handle(_ message: TransportMessage) -> [TransportReceiverAction] {
        switch message {
        case .hello(let hello): return handleHello(hello)
        case .authenticate(let auth): return handleAuthenticate(auth)
        case .ping: return seal(.pong).map { [$0] } ?? close()
        default:
            guard isAuthenticated else { return close() }
            return handleSession(message)
        }
    }

    private func handleHello(_ hello: HelloMessage) -> [TransportReceiverAction] {
        guard !isAuthenticated else { return close() }
        guard releaseTrain.acceptsPeer(hello.releaseTrain) else {
            return sealedThenClose(.error(ErrorMessage(code: 400, message: "Release train mismatch")))
        }
        guard hello.protocolVersion == protocolVersion else {
            return sealedThenClose(.error(.protocolMismatch(
                clientVersion: hello.protocolVersion, serverVersion: protocolVersion
            )))
        }
        device = (hello.deviceId, hello.deviceName)
        return []
    }

    private func handleAuthenticate(_ auth: AuthenticateMessage) -> [TransportReceiverAction] {
        guard !isAuthenticated, let device else { return close() }
        // The handshake already proved the code under the attempt limit, or a
        // credential in its place; this only confirms a sealed code agrees.
        guard usedCredential || pairing.validatePairingCode(auth.pairingCode) else {
            return sealedThenClose(.authResult(AuthResultMessage(
                success: false, errorMessage: "Invalid pairing code", releaseTrain: releaseTrain
            )))
        }
        isAuthenticated = true
        frameLimit = .session
        guard let result = seal(.authResult(AuthResultMessage(
            success: true, sessionToken: UUID().uuidString, releaseTrain: releaseTrain
        ))) else { return close() }
        pairing.addPairedDevice(id: device.id, name: device.name, credentialID: credentialID, now: now())
        return [result, .paired(deviceID: device.id, deviceName: device.name)]
    }

    private func handleSession(_ message: TransportMessage) -> [TransportReceiverAction] {
        switch message {
        case .sessionStart(let start):
            currentSessionID = start.sessionId
            return []
        case .transcriptChunk(let chunk):
            var actions: [TransportReceiverAction] = []
            if chunk.isFinal { actions.append(.deliver(sessionID: chunk.sessionId, text: chunk.text)) }
            if let ack = seal(.ack(AckMessage(sequenceNumber: chunk.sequenceNumber))) { actions.append(ack) }
            return actions
        case .sessionEnd:
            currentSessionID = nil
            return []
        default:
            return []
        }
    }
}
