import CryptoKit
import Foundation

// MARK: - Device credentials (#1643)
//
// See the header of `TransportSecureSession.swift` for why the pairing code is
// used only once and how a credential replaces it.

// MARK: - Key schedule

extension TransportKeySchedule {
    /// "Server finished", followed by a newly issued credential when there is one.
    static func serverFinished(issuing credential: TransportDeviceCredential?) -> Data {
        TransportHandshakeLabel.serverFinished(issuing: credential)
    }

    /// Reads an opened "server finished" frame. Throws unless it is exactly the
    /// marker, or the marker followed by one credential.
    static func credential(inServerFinished opened: Data) throws -> TransportDeviceCredential? {
        try TransportHandshakeLabel.credential(inServerFinished: opened)
    }

    /// The pre-shared key a phone and Mac hold once the Mac has issued `secret`.
    /// A different salt keeps it apart from every code-derived key.
    static func credentialKey(for secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: TransportHandshakeLabel.credentialKeySalt,
            info: TransportHandshakeLabel.preSharedKeyInfo,
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
