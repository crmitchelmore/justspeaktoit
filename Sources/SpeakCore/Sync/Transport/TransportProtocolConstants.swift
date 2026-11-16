import Foundation

/// The labels and sizes of the encrypted Send to Mac channel (protocol v2), in
/// one place.
///
/// `TransportHandshakeLabel` (both receivers and the Apple sender) reads
/// them, and `SendToMacProtocolAndroidExport` publishes them with test vectors
/// for the Android sender, so a change here reaches every sender at once. Each
/// label is part of the key schedule: changing one breaks every peer that
/// still uses the old one.
enum TransportProtocolConstants {
    /// Starts the transcript hash over both key-share frames.
    static let transcriptLabel = "justspeaktoit.send-to-mac.v2"
    /// Associated data of every sealed frame.
    static let frameAssociatedData = "justspeaktoit.send-to-mac.v2.frame"
    /// The phone's first sealed frame.
    static let clientFinished = "justspeaktoit.send-to-mac.v2 client finished"
    /// The Mac's first sealed frame, optionally followed by a device credential.
    static let serverFinished = "justspeaktoit.send-to-mac.v2 server finished"
    /// HKDF info of the phone-to-Mac key.
    static let clientToServerInfo = "justspeaktoit.send-to-mac.v2 client to server"
    /// HKDF info of the Mac-to-phone key.
    static let serverToClientInfo = "justspeaktoit.send-to-mac.v2 server to client"
    /// HKDF salt of the pre-shared key derived from the six-digit code.
    static let pairingKeySalt = "justspeaktoit.send-to-mac.pairing-key"
    /// HKDF salt of the pre-shared key derived from a device credential.
    static let credentialKeySalt = "justspeaktoit.send-to-mac.device-credential"
    /// HKDF info of both pre-shared keys.
    static let preSharedKeyInfo = "v2"

    /// Every derived key, and the X25519 keys and secret.
    static let keyByteCount = 32
    /// The Poly1305 tag appended to each sealed frame.
    static let tagByteCount = 16
    /// Four zero bytes, then the frame counter as a big-endian `UInt64`.
    static let nonceByteCount = 12
    /// A credential id: the UUID's 16 bytes in RFC 4122 order.
    static let credentialIDByteCount = 16
    static let credentialSecretByteCount = 32
}
