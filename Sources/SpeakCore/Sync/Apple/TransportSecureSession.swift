import CryptoKit
import Foundation

// MARK: - Encrypted Send to Mac channel (protocol v2)
//
// Every frame after one plaintext key share per direction is sealed with
// ChaCha20-Poly1305. The handshake is:
//
// 1. Phone → Mac, plaintext: `TransportKeyShare` (protocol version, ephemeral
//    X25519 public key).
// 2. Mac → Phone, plaintext: its own `TransportKeyShare`.
// 3. Both derive per-direction keys with HKDF-SHA256 from the X25519 secret, a
//    key HKDF-derived from the pairing code and a hash of both key-share frames.
// 4. Phone → Mac, sealed: "client finished". Only a phone that used the Mac's
//    current pairing code produces a frame the Mac can open, so this is the
//    pairing check and it goes through `PairingManager`'s attempt limit.
// 5. Mac → Phone, sealed: "server finished", proving the Mac knows the code too.
//    A wrong code or lockout gets a plaintext failure `authResult` instead,
//    which the phone only ever reads as a failure.
//
// Nonces are per-direction counters, so a replayed, reordered or dropped frame
// fails to open and closes the connection. The ephemeral keys make every
// session's keys unique, so frames cannot be replayed across sessions, and a
// passive observer who later learns the pairing code still cannot decrypt.
//
// The pairing code has six digits. The Mac never sends anything that depends on
// the code until the phone has proved it, so guessing against the Mac costs one
// rate-limited attempt per guess. A device that impersonates the Mac to the
// phone, however, receives the phone's "client finished" frame and can test
// codes against it offline.
//
// So the code is used once. A phone pairing with the code sets
// `requestsCredential` in its key share, and the Mac's "server finished" frame
// then carries a `TransportDeviceCredential`: a random 256-bit secret the Mac
// stores for that phone. Every later session names the credential in its key
// share and derives its keys from the secret in place of the code, so an
// impostor that captures a later "client finished" frame has nothing it can
// guess offline. A phone that holds a credential never falls back to the code
// on its own; re-pairing takes the user (#1643). The first pairing is still
// exposed to an impostor that is present at that moment.

/// One direction of the sealed channel. The nonce is the frame counter, so
/// frames must be opened in the order they were sealed, exactly once.
struct TransportFrameCipher: Sendable {
    private static let associatedData = TransportHandshakeLabel.frameAssociatedData
    static let overhead = TransportHandshakeLabel.tagByteCount

    private let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: self.key,
            nonce: try Self.nonce(self.counter),
            authenticating: Self.associatedData
        )
        self.counter += 1
        // `box.ciphertext` can be a slice that does not start at index 0.
        var frame = Data(capacity: box.ciphertext.count + Self.overhead)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= Self.overhead else { throw TransportSecurityError.unauthenticatedFrame }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try Self.nonce(self.counter),
                ciphertext: frame.dropLast(Self.overhead),
                tag: frame.suffix(Self.overhead)
            )
            let plaintext = try ChaChaPoly.open(box, using: self.key, authenticating: Self.associatedData)
            self.counter += 1
            return plaintext
        } catch {
            throw TransportSecurityError.unauthenticatedFrame
        }
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        guard let bytes = TransportHandshakeLabel.nonce(counter) else {
            throw TransportSecurityError.unauthenticatedFrame
        }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

/// Both directions of an established session, from one endpoint's point of view.
struct TransportSessionKeys: Sendable {
    var outbound: TransportFrameCipher
    var inbound: TransportFrameCipher
}

/// Shared handshake state once both key shares are known.
struct TransportKeySchedule: Sendable {
    enum Role: Sendable {
        case client
        case server
    }

    static let clientFinished = TransportHandshakeLabel.clientFinished
    static let serverFinished = TransportHandshakeLabel.serverFinished

    /// The X25519 secret. Internal only so the Android test vectors can publish it.
    let sharedSecret: Data
    /// SHA-256 over both key-share frames. Internal for the same reason.
    let transcriptHash: Data

    init(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        peerShare: TransportKeyShare,
        clientFrame: Data,
        serverFrame: Data
    ) throws {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerShare.keyShare)
        let secret = try localKey.sharedSecretFromKeyAgreement(with: peerKey)
        let secretBytes = secret.withUnsafeBytes { Data($0) }
        // A low-order peer key yields an all-zero secret that an attacker can predict.
        guard secretBytes.contains(where: { $0 != 0 }) else { throw TransportSecurityError.malformedHandshake }
        self.sharedSecret = secretBytes

        let transcript = TransportHandshakeLabel.transcript(clientFrame: clientFrame, serverFrame: serverFrame)
        self.transcriptHash = Data(SHA256.hash(data: transcript))
    }

    /// The pre-shared key both devices hold once the user has entered the code.
    static func pairingKey(for pairingCode: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pairingCode.utf8)),
            salt: TransportHandshakeLabel.pairingKeySalt,
            info: TransportHandshakeLabel.preSharedKeyInfo,
            outputByteCount: 32
        )
    }

    func sessionKeys(pairingCode: String, role: Role) -> TransportSessionKeys {
        self.sessionKeys(preSharedKey: Self.pairingKey(for: pairingCode), role: role)
    }

    func sessionKeys(preSharedKey: SymmetricKey, role: Role) -> TransportSessionKeys {
        let keys = self.directionKeys(preSharedKey: preSharedKey)
        let clientToServer = TransportFrameCipher(key: keys.clientToServer)
        let serverToClient = TransportFrameCipher(key: keys.serverToClient)
        switch role {
        case .client:
            return TransportSessionKeys(outbound: clientToServer, inbound: serverToClient)
        case .server:
            return TransportSessionKeys(outbound: serverToClient, inbound: clientToServer)
        }
    }

    /// The raw key for each direction, before either has sealed a frame.
    func directionKeys(preSharedKey: SymmetricKey) -> (clientToServer: SymmetricKey, serverToClient: SymmetricKey) {
        let pairingKey = preSharedKey.withUnsafeBytes { Data($0) }
        let inputKeyMaterial = SymmetricKey(data: self.sharedSecret + pairingKey)
        func key(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKeyMaterial,
                salt: self.transcriptHash,
                info: TransportHandshakeLabel.sessionKeyInfo(direction),
                outputByteCount: TransportProtocolConstants.keyByteCount
            )
        }
        return (key(TransportHandshakeLabel.clientToServer), key(TransportHandshakeLabel.serverToClient))
    }
}

// MARK: - Handshake roles

/// The phone's half of the handshake.
struct TransportClientHandshake {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let frame: Data
    let secret: TransportPairingSecret

    /// Starts a handshake that proves `secret`. A code-based handshake asks the
    /// Mac for a credential unless `requestsCredential` is false.
    init(
        protocolVersion: Int = SpeakTransportProtocolVersion,
        secret: TransportPairingSecret,
        requestsCredential: Bool = true
    ) throws {
        self.secret = secret
        var share = TransportKeyShare(
            protocolVersion: protocolVersion,
            keyShare: self.privateKey.publicKey.rawRepresentation
        )
        switch secret {
        case .code:
            share.requestsCredential = requestsCredential ? true : nil
        case .credential(let credential):
            share.credentialID = credential.id
        }
        self.frame = try share.encoded()
    }

    /// A code-based handshake that does not ask for a credential, as earlier builds send.
    init(protocolVersion: Int = SpeakTransportProtocolVersion) throws {
        try self.init(protocolVersion: protocolVersion, secret: .code(""), requestsCredential: false)
    }

    /// Derives the session from the Mac's key share and seals "client finished".
    func finish(serverFrame: Data) throws -> (keys: TransportSessionKeys, finished: Data) {
        guard let share = TransportKeyShare.decode(serverFrame) else {
            throw TransportSecurityError.malformedHandshake
        }
        let schedule = try TransportKeySchedule(
            localKey: self.privateKey,
            peerShare: share,
            clientFrame: self.frame,
            serverFrame: serverFrame
        )
        let preSharedKey = TransportKeySchedule.preSharedKey(for: self.secret)
        var keys = schedule.sessionKeys(preSharedKey: preSharedKey, role: .client)
        let finished = try keys.outbound.seal(TransportKeySchedule.clientFinished)
        return (keys, finished)
    }

    /// Derives the session from the Mac's key share with `pairingCode` and seals "client finished".
    func finish(serverFrame: Data, pairingCode: String) throws -> (keys: TransportSessionKeys, finished: Data) {
        guard let share = TransportKeyShare.decode(serverFrame) else {
            throw TransportSecurityError.malformedHandshake
        }
        let schedule = try TransportKeySchedule(
            localKey: self.privateKey,
            peerShare: share,
            clientFrame: self.frame,
            serverFrame: serverFrame
        )
        var keys = schedule.sessionKeys(pairingCode: pairingCode, role: .client)
        let finished = try keys.outbound.seal(TransportKeySchedule.clientFinished)
        return (keys, finished)
    }
}

/// The Mac's half of the handshake.
struct TransportServerHandshake {
    typealias Refusal = TransportHandshakeRefusal

    let frame: Data
    let schedule: TransportKeySchedule
    /// The phone's own key share, including any credential it named or asked for.
    let clientShare: TransportKeyShare

    init(clientFrame: Data, protocolVersion: Int = SpeakTransportProtocolVersion) throws {
        let share = try Refusal.keyShare(in: clientFrame, protocolVersion: protocolVersion)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let frame = try TransportKeyShare(
            protocolVersion: protocolVersion,
            keyShare: privateKey.publicKey.rawRepresentation
        ).encoded()
        do {
            self.schedule = try TransportKeySchedule(
                localKey: privateKey,
                peerShare: share,
                clientFrame: clientFrame,
                serverFrame: frame
            )
        } catch {
            throw Refusal.malformed
        }
        self.frame = frame
        self.clientShare = share
    }
}
