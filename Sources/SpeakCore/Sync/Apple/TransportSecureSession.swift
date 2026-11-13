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

/// The peer refused the connection and said why, for example a wrong pairing
/// code, a lockout or a protocol-version mismatch.
public struct TransportRejection: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        self.message
    }
}

/// Failures of the encrypted channel itself.
public enum TransportSecurityError: Error, Equatable, Sendable {
    /// A message was sent or received before the encrypted session existed.
    case notEncrypted
    /// A frame failed authentication: wrong key, tampered, replayed or reordered.
    case unauthenticatedFrame
    /// The peer's handshake frame was not a valid key share.
    case malformedHandshake
}

extension TransportSecurityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEncrypted:
            "The connection is not encrypted yet"
        case .unauthenticatedFrame:
            "Received a message that was not sealed with this session's key"
        case .malformedHandshake:
            "The peer sent an invalid encryption handshake"
        }
    }
}

/// The only plaintext frame each side sends in protocol v2.
///
/// The optional fields are omitted when unset, so a key share without them is
/// byte-for-byte what earlier builds send, and earlier Macs ignore them.
struct TransportKeyShare: Codable, Equatable {
    var protocolVersion: Int
    /// Raw X25519 public key, 32 bytes.
    var keyShare: Data
    /// Phone only: the credential this session is keyed with, instead of the code.
    var credentialID: UUID?
    /// Phone only: asks the Mac to issue a credential once the code is proved.
    var requestsCredential: Bool?

    static func decode(_ frame: Data) -> TransportKeyShare? {
        guard let share = try? JSONDecoder().decode(TransportKeyShare.self, from: frame),
              share.keyShare.count == 32 else { return nil }
        return share
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// One direction of the sealed channel. The nonce is the frame counter, so
/// frames must be opened in the order they were sealed, exactly once.
struct TransportFrameCipher: Sendable {
    private static let associatedData = Data("justspeaktoit.send-to-mac.v2.frame".utf8)
    static let overhead = 16

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
        guard counter < UInt64.max else { throw TransportSecurityError.unauthenticatedFrame }
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
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

    static let clientFinished = Data("justspeaktoit.send-to-mac.v2 client finished".utf8)
    static let serverFinished = Data("justspeaktoit.send-to-mac.v2 server finished".utf8)

    private let sharedSecret: Data
    private let transcriptHash: Data

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

        var transcript = SHA256()
        transcript.update(data: Data("justspeaktoit.send-to-mac.v2".utf8))
        for frame in [clientFrame, serverFrame] {
            withUnsafeBytes(of: UInt32(frame.count).bigEndian) { transcript.update(bufferPointer: $0) }
            transcript.update(data: frame)
        }
        self.transcriptHash = Data(transcript.finalize())
    }

    /// The pre-shared key both devices hold once the user has entered the code.
    static func pairingKey(for pairingCode: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pairingCode.utf8)),
            salt: Data("justspeaktoit.send-to-mac.pairing-key".utf8),
            info: Data("v2".utf8),
            outputByteCount: 32
        )
    }

    func sessionKeys(pairingCode: String, role: Role) -> TransportSessionKeys {
        self.sessionKeys(preSharedKey: Self.pairingKey(for: pairingCode), role: role)
    }

    func sessionKeys(preSharedKey: SymmetricKey, role: Role) -> TransportSessionKeys {
        let pairingKey = preSharedKey.withUnsafeBytes { Data($0) }
        let inputKeyMaterial = SymmetricKey(data: self.sharedSecret + pairingKey)
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKeyMaterial,
                salt: self.transcriptHash,
                info: Data("justspeaktoit.send-to-mac.v2 \(label)".utf8),
                outputByteCount: 32
            )
        }
        let clientToServer = TransportFrameCipher(key: key("client to server"))
        let serverToClient = TransportFrameCipher(key: key("server to client"))
        switch role {
        case .client:
            return TransportSessionKeys(outbound: clientToServer, inbound: serverToClient)
        case .server:
            return TransportSessionKeys(outbound: serverToClient, inbound: clientToServer)
        }
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
    enum Refusal: Error, Equatable {
        /// A plaintext `hello` from a peer that does not encrypt.
        case plaintextHello(protocolVersion: Int)
        case versionMismatch(protocolVersion: Int)
        case malformed
    }

    let frame: Data
    let schedule: TransportKeySchedule
    /// The phone's own key share, including any credential it named or asked for.
    let clientShare: TransportKeyShare

    init(clientFrame: Data, protocolVersion: Int = SpeakTransportProtocolVersion) throws {
        guard let share = TransportKeyShare.decode(clientFrame) else {
            if case .hello(let hello)? = try? Self.plaintextDecoder.decode(TransportMessage.self, from: clientFrame) {
                throw Refusal.plaintextHello(protocolVersion: hello.protocolVersion)
            }
            throw Refusal.malformed
        }
        guard share.protocolVersion == protocolVersion else {
            throw Refusal.versionMismatch(protocolVersion: share.protocolVersion)
        }
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

    private static let plaintextDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
