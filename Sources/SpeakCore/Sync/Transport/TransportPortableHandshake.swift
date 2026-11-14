import Foundation

// MARK: - Portable Send to Mac v2 handshake
//
// The same protocol as `Sync/Apple/TransportSecureSession.swift`, built on the
// portable primitives in `Crypto/` for receivers without CryptoKit (Windows and
// Linux). Labels, framing and key-share encoding come from
// `TransportHandshakeWire.swift`, which the CryptoKit implementation also uses,
// and interoperability tests run the CryptoKit phone against this receiver.

/// Why a receiver refused a phone's first frame.
enum TransportHandshakeRefusal: Error, Equatable {
    /// A plaintext `hello` from a peer that does not encrypt.
    case plaintextHello(protocolVersion: Int)
    case versionMismatch(protocolVersion: Int)
    case malformed

    private static let plaintextDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The phone's key share, or the refusal for a frame that is not one.
    static func keyShare(in clientFrame: Data, protocolVersion: Int) throws -> TransportKeyShare {
        guard let share = TransportKeyShare.decode(clientFrame) else {
            if case .hello(let hello)? = try? Self.plaintextDecoder.decode(TransportMessage.self, from: clientFrame) {
                throw Self.plaintextHello(protocolVersion: hello.protocolVersion)
            }
            throw Self.malformed
        }
        guard share.protocolVersion == protocolVersion else {
            throw Self.versionMismatch(protocolVersion: share.protocolVersion)
        }
        return share
    }

    /// The plaintext error the phone is sent, or nil to close without one.
    func reply(serverVersion: Int, wording: TransportReceiverWording) -> ErrorMessage? {
        switch self {
        case .plaintextHello(let version) where version == serverVersion:
            ErrorMessage(code: 426, message: wording.encryptionRequired)
        case .plaintextHello(let version), .versionMismatch(let version):
            .protocolMismatch(clientVersion: version, serverVersion: serverVersion)
        case .malformed:
            nil
        }
    }
}

/// One direction of the sealed channel; the nonce is the frame counter.
struct TransportPortableFrameCipher: Sendable {
    private let key: [UInt8]
    private(set) var counter: UInt64 = 0

    init(key: [UInt8]) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard let nonce = TransportHandshakeLabel.nonce(counter) else {
            throw TransportSecurityError.unauthenticatedFrame
        }
        let frame = PortableChaChaPoly.seal(
            Array(plaintext), key: key, nonce: Array(nonce),
            authenticating: Array(TransportHandshakeLabel.frameAssociatedData)
        )
        counter += 1
        return Data(frame)
    }

    mutating func open(_ frame: Data) throws -> Data {
        guard let nonce = TransportHandshakeLabel.nonce(counter),
              let plaintext = PortableChaChaPoly.open(
                  Array(frame), key: key, nonce: Array(nonce),
                  authenticating: Array(TransportHandshakeLabel.frameAssociatedData)
              ) else { throw TransportSecurityError.unauthenticatedFrame }
        counter += 1
        return Data(plaintext)
    }
}

struct TransportPortableSessionKeys: Sendable {
    var outbound: TransportPortableFrameCipher
    var inbound: TransportPortableFrameCipher
}

/// Shared handshake state once both key shares are known.
struct TransportPortableKeySchedule: Sendable {
    enum Role: Sendable {
        case client
        case server
    }

    private let sharedSecret: [UInt8]
    private let transcriptHash: [UInt8]

    init(privateKey: [UInt8], peerShare: TransportKeyShare, clientFrame: Data, serverFrame: Data) throws {
        let peerKey = Array(peerShare.keyShare)
        guard let secret = PortableX25519.sharedSecret(privateKey: privateKey, peerPublicKey: peerKey),
              secret.contains(where: { $0 != 0 }) else { throw TransportSecurityError.malformedHandshake }
        self.sharedSecret = secret
        self.transcriptHash = PortableSHA256.hash(
            Array(TransportHandshakeLabel.transcript(clientFrame: clientFrame, serverFrame: serverFrame))
        )
    }

    static func pairingKey(for pairingCode: String) -> [UInt8] {
        PortableHKDF.deriveKey(
            inputKeyMaterial: Array(pairingCode.utf8), salt: Array(TransportHandshakeLabel.pairingKeySalt),
            info: Array(TransportHandshakeLabel.preSharedKeyInfo), outputByteCount: 32
        )
    }

    static func credentialKey(for secret: Data) -> [UInt8] {
        PortableHKDF.deriveKey(
            inputKeyMaterial: Array(secret), salt: Array(TransportHandshakeLabel.credentialKeySalt),
            info: Array(TransportHandshakeLabel.preSharedKeyInfo), outputByteCount: 32
        )
    }

    static func preSharedKey(for secret: TransportPairingSecret) -> [UInt8] {
        switch secret {
        case .code(let code): pairingKey(for: code)
        case .credential(let credential): credentialKey(for: credential.secret)
        }
    }

    func sessionKeys(preSharedKey: [UInt8], role: Role) -> TransportPortableSessionKeys {
        let inputKeyMaterial = sharedSecret + preSharedKey
        func cipher(_ direction: String) -> TransportPortableFrameCipher {
            TransportPortableFrameCipher(key: PortableHKDF.deriveKey(
                inputKeyMaterial: inputKeyMaterial, salt: transcriptHash,
                info: Array(TransportHandshakeLabel.sessionKeyInfo(direction)), outputByteCount: 32
            ))
        }
        let clientToServer = cipher(TransportHandshakeLabel.clientToServer)
        let serverToClient = cipher(TransportHandshakeLabel.serverToClient)
        switch role {
        case .client: return TransportPortableSessionKeys(outbound: clientToServer, inbound: serverToClient)
        case .server: return TransportPortableSessionKeys(outbound: serverToClient, inbound: clientToServer)
        }
    }
}

/// The receiver's half of the handshake.
struct TransportPortableServerHandshake {
    let frame: Data
    let schedule: TransportPortableKeySchedule
    let clientShare: TransportKeyShare

    init(clientFrame: Data, protocolVersion: Int = SpeakTransportProtocolVersion, privateKey: [UInt8]? = nil) throws {
        let share = try TransportHandshakeRefusal.keyShare(in: clientFrame, protocolVersion: protocolVersion)
        let key = privateKey ?? PortableX25519.generatePrivateKey()
        let frame = try TransportKeyShare(
            protocolVersion: protocolVersion, keyShare: Data(PortableX25519.publicKey(privateKey: key))
        ).encoded()
        do {
            self.schedule = try TransportPortableKeySchedule(
                privateKey: key, peerShare: share, clientFrame: clientFrame, serverFrame: frame
            )
        } catch {
            throw TransportHandshakeRefusal.malformed
        }
        self.frame = frame
        self.clientShare = share
    }
}

/// The phone's half of the handshake, for portable tests and tools.
struct TransportPortableClientHandshake {
    private let privateKey: [UInt8]
    let frame: Data
    let secret: TransportPairingSecret

    init(
        protocolVersion: Int = SpeakTransportProtocolVersion, secret: TransportPairingSecret,
        requestsCredential: Bool = true, privateKey: [UInt8]? = nil
    ) throws {
        self.privateKey = privateKey ?? PortableX25519.generatePrivateKey()
        self.secret = secret
        var share = TransportKeyShare(
            protocolVersion: protocolVersion, keyShare: Data(PortableX25519.publicKey(privateKey: self.privateKey))
        )
        switch secret {
        case .code: share.requestsCredential = requestsCredential ? true : nil
        case .credential(let credential): share.credentialID = credential.id
        }
        self.frame = try share.encoded()
    }

    func finish(serverFrame: Data) throws -> (keys: TransportPortableSessionKeys, finished: Data) {
        guard let share = TransportKeyShare.decode(serverFrame) else { throw TransportSecurityError.malformedHandshake }
        let schedule = try TransportPortableKeySchedule(
            privateKey: privateKey, peerShare: share, clientFrame: frame, serverFrame: serverFrame
        )
        var keys = schedule.sessionKeys(
            preSharedKey: TransportPortableKeySchedule.preSharedKey(for: secret), role: .client
        )
        let finished = try keys.outbound.seal(TransportHandshakeLabel.clientFinished)
        return (keys, finished)
    }
}
