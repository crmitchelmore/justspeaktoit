import CryptoKit
import Foundation

// MARK: - Device credentials (#1643)
//
// See the header of `TransportSecureSession.swift` for why the pairing code is
// used only once and how a credential replaces it.

/// A high-entropy key the Mac issues to one phone after it proves the pairing
/// code. Later sessions authenticate with it instead of the code.
public struct TransportDeviceCredential: Codable, Equatable, Sendable {
    static let secretByteCount = 32

    /// Names the credential in the phone's key share. Not secret.
    public let id: UUID
    /// 32 random bytes. Never sent again after the Mac issues it.
    public let secret: Data

    public init(id: UUID, secret: Data) {
        self.id = id
        self.secret = secret
    }

    static func generate() -> TransportDeviceCredential {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return TransportDeviceCredential(id: UUID(), secret: secret)
    }

    /// The credential as the Mac appends it to "server finished": id, then secret.
    var wireBytes: Data {
        withUnsafeBytes(of: self.id.uuid) { Data($0) } + self.secret
    }

    init?(wireBytes: Data) {
        guard wireBytes.count == 16 + Self.secretByteCount else { return nil }
        let bytes = Array(wireBytes)
        let id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        self.init(id: id, secret: Data(bytes[16...]))
    }
}

/// What the phone proves in the handshake: the six-digit code at pairing, or the
/// credential the Mac issued then.
public enum TransportPairingSecret: Sendable, Equatable {
    case code(String)
    case credential(TransportDeviceCredential)
}

// MARK: - Key schedule

extension TransportKeySchedule {
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

    /// The pre-shared key a phone and Mac hold once the Mac has issued `secret`.
    /// A different salt keeps it apart from every code-derived key.
    static func credentialKey(for secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("justspeaktoit.send-to-mac.device-credential".utf8),
            info: Data("v2".utf8),
            outputByteCount: 32
        )
    }

    static func preSharedKey(for secret: TransportPairingSecret) -> SymmetricKey {
        switch secret {
        case .code(let code):
            Self.pairingKey(for: code)
        case .credential(let credential):
            Self.credentialKey(for: credential.secret)
        }
    }
}

// MARK: - Mac-side proof

/// The phone's "client finished" frame, checked against a candidate pairing
/// code or device credential.
///
/// The Mac hands this to `PairingManager.authorize(_:)`, which supplies the
/// current code or the named credential under its lock and counts a wrong code
/// against the attempt limit. A successful check keeps the session keys it
/// derived.
public final class TransportPairingProof: @unchecked Sendable {
    private let schedule: TransportKeySchedule
    private let clientFinished: Data
    private let lock = NSLock()
    private var verifiedKeys: TransportSessionKeys?
    private var credentialToIssue: TransportDeviceCredential?

    /// The credential the phone keyed this session with, or nil for the code.
    public let credentialID: UUID?
    /// Whether the phone asked for a credential once it proves the code.
    public let requestsCredential: Bool

    init(
        schedule: TransportKeySchedule,
        clientFinished: Data,
        credentialID: UUID? = nil,
        requestsCredential: Bool = false
    ) {
        self.schedule = schedule
        self.clientFinished = clientFinished
        self.credentialID = credentialID
        self.requestsCredential = credentialID == nil && requestsCredential
    }

    /// Whether the phone sealed its handshake with `pairingCode`. Always false
    /// when the phone named a credential instead.
    public func verifies(pairingCode: String) -> Bool {
        guard self.credentialID == nil else { return false }
        return self.verifies(preSharedKey: TransportKeySchedule.pairingKey(for: pairingCode))
    }

    /// Whether the phone sealed its handshake with the credential it named.
    public func verifies(credential: TransportDeviceCredential) -> Bool {
        guard self.credentialID == credential.id else { return false }
        return self.verifies(preSharedKey: TransportKeySchedule.credentialKey(for: credential.secret))
    }

    private func verifies(preSharedKey: SymmetricKey) -> Bool {
        var keys = self.schedule.sessionKeys(preSharedKey: preSharedKey, role: .server)
        guard let opened = try? keys.inbound.open(self.clientFinished),
              opened == TransportKeySchedule.clientFinished else { return false }
        self.lock.withLock { self.verifiedKeys = keys }
        return true
    }

    /// Hands a newly issued credential to the phone in "server finished".
    /// Ignored unless the phone proved the code and asked for one.
    func issue(_ credential: TransportDeviceCredential) {
        guard self.requestsCredential else { return }
        self.lock.withLock { self.credentialToIssue = credential }
    }

    var acceptedKeys: TransportSessionKeys? {
        self.lock.withLock { self.verifiedKeys }
    }

    var issuedCredential: TransportDeviceCredential? {
        self.lock.withLock { self.credentialToIssue }
    }
}
