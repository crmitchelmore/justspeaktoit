import Foundation

// MARK: - Send to Mac protocol v2 wire constants
//
// The encrypted handshake is described in `Sync/Apple/TransportSecureSession.swift`.
// Everything both receivers and senders must agree on byte for byte lives here,
// so the CryptoKit implementation (Apple) and the portable one (Windows and
// Linux, `TransportPortableHandshake.swift`) cannot drift apart.

/// Labels, salts and framing of the v2 key schedule.
enum TransportHandshakeLabel {
    private typealias Constants = TransportProtocolConstants
    static let transcriptPrefix = Data(Constants.transcriptLabel.utf8)
    static let frameAssociatedData = Data(Constants.frameAssociatedData.utf8)
    static let clientFinished = Data(Constants.clientFinished.utf8)
    static let serverFinished = Data(Constants.serverFinished.utf8)
    static let pairingKeySalt = Data(Constants.pairingKeySalt.utf8)
    static let credentialKeySalt = Data(Constants.credentialKeySalt.utf8)
    static let preSharedKeyInfo = Data(Constants.preSharedKeyInfo.utf8)
    static let clientToServer = Constants.clientToServerInfo
    static let serverToClient = Constants.serverToClientInfo
    static let tagByteCount = Constants.tagByteCount

    /// HKDF info of one direction's session key; `direction` is the full label.
    static func sessionKeyInfo(_ direction: String) -> Data {
        Data(direction.utf8)
    }

    /// The bytes hashed into the transcript: a prefix, then each key-share frame
    /// preceded by its length as a big-endian UInt32.
    static func transcript(clientFrame: Data, serverFrame: Data) -> Data {
        var transcript = Self.transcriptPrefix
        for frame in [clientFrame, serverFrame] {
            withUnsafeBytes(of: UInt32(frame.count).bigEndian) { transcript.append(contentsOf: $0) }
            transcript.append(frame)
        }
        return transcript
    }

    /// "Server finished", followed by a newly issued credential when there is one.
    static func serverFinished(issuing credential: TransportDeviceCredential?) -> Data {
        Self.serverFinished + (credential?.wireBytes ?? Data())
    }

    /// Reads an opened "server finished" frame. Throws unless it is exactly the
    /// marker, or the marker followed by one credential.
    static func credential(inServerFinished opened: Data) throws -> TransportDeviceCredential? {
        guard opened.starts(with: Self.serverFinished) else { throw TransportSecurityError.unauthenticatedFrame }
        let rest = opened.dropFirst(Self.serverFinished.count)
        guard !rest.isEmpty else { return nil }
        guard let credential = TransportDeviceCredential(wireBytes: Data(rest)) else {
            throw TransportSecurityError.unauthenticatedFrame
        }
        return credential
    }

    /// The 96-bit ChaCha20-Poly1305 nonce for one frame: four zero bytes, then
    /// the frame counter big-endian. Nil once the counter is exhausted.
    static func nonce(_ counter: UInt64) -> Data? {
        guard counter < UInt64.max else { return nil }
        var bytes = Data(count: TransportProtocolConstants.nonceByteCount - MemoryLayout<UInt64>.size)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }
}

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
              share.keyShare.count == TransportProtocolConstants.keyByteCount else { return nil }
        return share
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

// MARK: - Device credentials (#1643)

/// A high-entropy key the Mac issues to one phone after it proves the pairing
/// code. Later sessions authenticate with it instead of the code.
public struct TransportDeviceCredential: Codable, Equatable, Sendable {
    static let secretByteCount = TransportProtocolConstants.credentialSecretByteCount

    /// Names the credential in the phone's key share. Not secret.
    public let id: UUID
    /// 32 random bytes. Never sent again after the Mac issues it.
    public let secret: Data

    public init(id: UUID, secret: Data) {
        self.id = id
        self.secret = secret
    }

    static func generate() -> TransportDeviceCredential {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<Self.secretByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return TransportDeviceCredential(id: UUID(), secret: secret)
    }

    /// The credential as the Mac appends it to "server finished": id, then secret.
    var wireBytes: Data {
        withUnsafeBytes(of: self.id.uuid) { Data($0) } + self.secret
    }

    init?(wireBytes: Data) {
        guard wireBytes.count == TransportProtocolConstants.credentialIDByteCount + Self.secretByteCount else {
            return nil
        }
        let bytes = Array(wireBytes)
        let id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        self.init(id: id, secret: Data(bytes[TransportProtocolConstants.credentialIDByteCount...]))
    }
}

/// What the phone proves in the handshake: the six-digit code at pairing, or the
/// credential the Mac issued then.
public enum TransportPairingSecret: Sendable, Equatable {
    case code(String)
    case credential(TransportDeviceCredential)
}
