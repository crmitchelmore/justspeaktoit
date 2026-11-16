import CryptoKit
import Foundation

/// The Send to Mac wire contract as JSON for the Android sender: protocol
/// version, Bonjour service types, frame limits, every key-schedule label and
/// deterministic test vectors made with the real handshake types.
///
/// Android reads the constants from this asset at run time and its
/// `SendToMacProtocolVectorTest` replays the vectors byte for byte, so the
/// Kotlin port cannot drift from `TransportSecureSession.swift`. The phone's
/// messages in `messages.phone` are the exact bytes Android sends;
/// `SendToMacProtocolAndroidExportTests` proves the Mac decodes them.
/// `SendToMacProtocolAndroidExportTests` also fails when the committed asset is
/// stale; regenerate it with `scripts/update-android-assets`.
public enum SendToMacProtocolAndroidExport {
    static let pairingCode = "482915"
    static let deviceName = "Pixel 9"
    static let deviceID = "8C0F7D2E-5B1A-4E8B-9C3D-2A6F1E0B7C45"
    static let sessionID = "D3B07384-D9A0-4E5B-9F1C-6A2B3C4D5E6F"
    static let model = "deepgram/nova-3"
    static let timestamp = "2026-01-02T03:04:05Z"
    /// Quotes, a newline, a slash and non-ASCII text, which JSON writers escape differently.
    static let transcript = "Hello \"Mac\"\nfrom Android — café 🎙️ / done"
    static let credential = TransportDeviceCredential(
        id: UUID(uuid: (
            0x6F, 0x96, 0x19, 0xFF, 0x8B, 0x86, 0xD0, 0x11, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF
        )),
        secret: Data((0 ..< 32).map { UInt8(0xA0 + $0) })
    )
    static let clientPrivateKey = Data((1 ... 32).map { UInt8($0) })
    static let serverPrivateKey = Data((33 ... 64).map { UInt8($0) })

    /// The messages Android sends, exactly as it writes them.
    static let phoneMessages: [String: String] = [
        "hello": #"{"type":"hello","payload":{"protocolVersion":2,"deviceName":"Pixel 9","#
            + #""deviceId":"8C0F7D2E-5B1A-4E8B-9C3D-2A6F1E0B7C45","releaseTrain":"stable"}}"#,
        "authenticatePairing": #"{"type":"authenticate","payload":{"pairingCode":"482915","#
            + #""timestamp":"2026-01-02T03:04:05Z"}}"#,
        "authenticateCredential": #"{"type":"authenticate","payload":{"pairingCode":"","#
            + #""timestamp":"2026-01-02T03:04:05Z"}}"#,
        "sessionStart": #"{"type":"sessionStart","payload":{"sessionId":"D3B07384-D9A0-4E5B-9F1C-6A2B3C4D5E6F","#
            + #""model":"deepgram/nova-3","language":"en-US"}}"#,
        "transcriptChunk": #"{"type":"transcriptChunk","payload":{"#
            + #""sessionId":"D3B07384-D9A0-4E5B-9F1C-6A2B3C4D5E6F","sequenceNumber":1,"#
            + #""text":"Hello \"Mac\"\nfrom Android — café 🎙️ / done","isFinal":true,"#
            + #""timestamp":"2026-01-02T03:04:05Z"}}"#,
        "sessionEnd": #"{"type":"sessionEnd","payload":{"sessionId":"D3B07384-D9A0-4E5B-9F1C-6A2B3C4D5E6F","#
            + #""finalText":"Hello \"Mac\"\nfrom Android — café 🎙️ / done","duration":12.5,"wordCount":9}}"#,
        "pong": #"{"type":"pong"}"#
    ]

    /// Messages the Mac sends, as its `TransportChannel` encodes them (keys sorted
    /// here only so the asset is stable).
    static func macMessages() throws -> [String: String] {
        let messages: [String: TransportMessage] = [
            "authResultSuccess": .authResult(AuthResultMessage(
                success: true, sessionToken: "vector-session-token", releaseTrain: .stable
            )),
            "authResultLegacySuccess": .authResult(AuthResultMessage(
                success: true, sessionToken: "vector-session-token", releaseTrain: nil
            )),
            "authResultAlpha": .authResult(AuthResultMessage(
                success: true, sessionToken: "vector-session-token", releaseTrain: .alpha
            )),
            "authResultFailure": .authResult(AuthResultMessage(
                success: false, errorMessage: "Invalid pairing code", releaseTrain: nil
            )),
            "ack": .ack(AckMessage(sequenceNumber: 1)),
            "error": .error(.authenticationFailed),
            "ping": .ping
        ]
        return try messages.mapValues { try Self.utf8(Self.messageEncoder.encode($0)) }
    }

    /// The key share Android sends: compact, in this field order, with the
    /// credential id in upper case.
    static func phoneKeyShare(publicKey: Data, secret: TransportPairingSecret) -> String {
        let prefix = #"{"protocolVersion":2,"keyShare":""# + publicKey.base64EncodedString() + "\""
        switch secret {
        case .code:
            return prefix + #","requestsCredential":true}"#
        case .credential(let credential):
            return prefix + #","credentialID":""# + credential.id.uuidString + #""}"#
        }
    }

    public static func json() throws -> Data {
        let document = Document(
            version: 1,
            protocolVersion: SpeakTransportProtocolVersion,
            serviceTypes: Dictionary(
                uniqueKeysWithValues: ReleaseTrain.allCases.map { ($0.rawValue, $0.bonjourService) }
            ),
            endpointPath: SpeakTransportWire.endpointPath,
            handshakeFrameLimitBytes: TransportFrameLimit.handshake.maximumBytes,
            sessionFrameLimitBytes: TransportFrameLimit.session.maximumBytes,
            labels: Labels(),
            sizes: Sizes(),
            revokedCredentialMessage: TransportChannel.revokedCredentialMessage,
            vectors: Vectors(
                clientPrivateKey: Self.hex(Self.clientPrivateKey),
                serverPrivateKey: Self.hex(Self.serverPrivateKey),
                pairing: try Self.handshake(secret: .code(Self.pairingCode), issuing: Self.credential),
                credential: try Self.handshake(secret: .credential(Self.credential), issuing: nil)
            ),
            messages: Messages(phone: Self.phoneMessages, mac: try Self.macMessages())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    /// One handshake from both ends with fixed keys: the Mac's side through the
    /// same schedule `TransportServerHandshake` uses, the phone's independently.
    static func handshake(secret: TransportPairingSecret, issuing: TransportDeviceCredential?) throws -> Handshake {
        let clientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.clientPrivateKey)
        let serverKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.serverPrivateKey)
        let clientShareText = Self.phoneKeyShare(publicKey: clientKey.publicKey.rawRepresentation, secret: secret)
        let clientFrame = Data(clientShareText.utf8)
        let serverShare = TransportKeyShare(
            protocolVersion: SpeakTransportProtocolVersion,
            keyShare: serverKey.publicKey.rawRepresentation
        )
        let serverFrame = try Self.messageEncoder.encode(serverShare)
        guard let clientShare = TransportKeyShare.decode(clientFrame) else {
            throw TransportSecurityError.malformedHandshake
        }
        let macSchedule = try TransportKeySchedule(
            localKey: serverKey, peerShare: clientShare, clientFrame: clientFrame, serverFrame: serverFrame
        )
        let phoneSchedule = try TransportKeySchedule(
            localKey: clientKey, peerShare: serverShare, clientFrame: clientFrame, serverFrame: serverFrame
        )
        let preSharedKey = TransportKeySchedule.preSharedKey(for: secret)
        var phone = phoneSchedule.sessionKeys(preSharedKey: preSharedKey, role: .client)
        var mac = macSchedule.sessionKeys(preSharedKey: preSharedKey, role: .server)
        let directions = macSchedule.directionKeys(preSharedKey: preSharedKey)
        let phoneMessage = Self.phoneMessages["hello", default: ""]
        let macMessage = try Self.macMessages()["authResultSuccess", default: ""]
        let clientFrameText = try Self.utf8(clientFrame)
        let serverFrameText = try Self.utf8(serverFrame)
        return Handshake(
            clientPublicKey: Self.hex(clientKey.publicKey.rawRepresentation),
            serverPublicKey: Self.hex(serverKey.publicKey.rawRepresentation),
            clientFrame: clientFrameText,
            serverFrame: serverFrameText,
            sharedSecret: Self.hex(phoneSchedule.sharedSecret),
            transcriptHash: Self.hex(phoneSchedule.transcriptHash),
            preSharedKey: Self.hex(preSharedKey.withUnsafeBytes { Data($0) }),
            clientToServerKey: Self.hex(directions.clientToServer.withUnsafeBytes { Data($0) }),
            serverToClientKey: Self.hex(directions.serverToClient.withUnsafeBytes { Data($0) }),
            clientFinished: Self.hex(try phone.outbound.seal(TransportKeySchedule.clientFinished)),
            serverFinished: Self.hex(try mac.outbound.seal(TransportKeySchedule.serverFinished(issuing: issuing))),
            issuedCredential: issuing.map { Credential(id: $0.id.uuidString, secret: Self.hex($0.secret)) },
            phoneMessage: Sealed(
                json: phoneMessage, sealed: Self.hex(try phone.outbound.seal(Data(phoneMessage.utf8)))
            ),
            macMessage: Sealed(json: macMessage, sealed: Self.hex(try mac.outbound.seal(Data(macMessage.utf8))))
        )
    }

    static func utf8(_ data: Data) throws -> String {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw TransportSecurityError.malformedHandshake
        }
        return text
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static var messageEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Document

    struct Document: Encodable {
        let version: Int
        let protocolVersion: Int
        /// Release train → DNS-SD service type. A phone browses its own train's.
        let serviceTypes: [String: String]
        let endpointPath: String
        let handshakeFrameLimitBytes: Int
        let sessionFrameLimitBytes: Int
        let labels: Labels
        let sizes: Sizes
        let revokedCredentialMessage: String
        let vectors: Vectors
        let messages: Messages
    }

    struct Labels: Encodable {
        var transcript = TransportProtocolConstants.transcriptLabel
        var frameAssociatedData = TransportProtocolConstants.frameAssociatedData
        var clientFinished = TransportProtocolConstants.clientFinished
        var serverFinished = TransportProtocolConstants.serverFinished
        var clientToServerInfo = TransportProtocolConstants.clientToServerInfo
        var serverToClientInfo = TransportProtocolConstants.serverToClientInfo
        var pairingKeySalt = TransportProtocolConstants.pairingKeySalt
        var credentialKeySalt = TransportProtocolConstants.credentialKeySalt
        var preSharedKeyInfo = TransportProtocolConstants.preSharedKeyInfo
    }

    struct Sizes: Encodable {
        var key = TransportProtocolConstants.keyByteCount
        var tag = TransportProtocolConstants.tagByteCount
        var nonce = TransportProtocolConstants.nonceByteCount
        var credentialID = TransportProtocolConstants.credentialIDByteCount
        var credentialSecret = TransportProtocolConstants.credentialSecretByteCount
    }

    struct Vectors: Encodable {
        let clientPrivateKey: String
        let serverPrivateKey: String
        /// First pairing with the six-digit code; the Mac issues `issuedCredential`.
        let pairing: Handshake
        /// A later send keyed with that credential.
        let credential: Handshake
    }

    /// Byte strings are lower-case hex; frames are UTF-8 text.
    struct Handshake: Encodable {
        let clientPublicKey: String
        let serverPublicKey: String
        let clientFrame: String
        let serverFrame: String
        let sharedSecret: String
        let transcriptHash: String
        let preSharedKey: String
        let clientToServerKey: String
        let serverToClientKey: String
        /// Sealed with the phone's counter 0.
        let clientFinished: String
        /// Sealed with the Mac's counter 0.
        let serverFinished: String
        let issuedCredential: Credential?
        /// `messages.phone.hello` sealed with the phone's counter 1.
        let phoneMessage: Sealed
        /// `messages.mac.authResultSuccess` sealed with the Mac's counter 1.
        let macMessage: Sealed
    }

    struct Credential: Encodable {
        let id: String
        let secret: String
    }

    struct Sealed: Encodable {
        let json: String
        let sealed: String
    }

    struct Messages: Encodable {
        let phone: [String: String]
        let mac: [String: String]
    }
}
