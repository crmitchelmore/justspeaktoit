import Foundation

// MARK: - Pairing

/// Manages pairing codes for device authentication.
///
/// `@unchecked` only because `UserDefaults` lacks a Sendable annotation in the
/// SDK. Every pairing-code and paired-device transaction is serialized behind
/// one `NSLock` — `UserDefaults` alone is thread-safe per call, but the
/// read-modify-write sequences here need a single owner to avoid losing
/// entries or minting competing codes.
public final class PairingManager: @unchecked Sendable {
    public static let shared = PairingManager()

    private let defaults: UserDefaults
    private let pairingCodeKey = "speakTransportPairingCode"
    private let pairedDevicesKey = "speakTransportPairedDevices"
    /// Device credentials issued to phones that proved the code (#1643). They sit
    /// beside the code in the same store and are revoked with it.
    private let credentialsKey = "speakTransportDeviceCredentials"
    /// Oldest credentials are dropped beyond this, so repeated pairings cannot
    /// grow the store without bound.
    static let maximumCredentials = 32
    /// Serializes all read-modify-write transactions below. Not reentrant:
    /// public members take it once and only call `...Unlocked` helpers inside.
    private let lock = NSLock()
    /// Server-wide, not per connection: a peer that opens a fresh connection
    /// for every guess still spends the same failure budget.
    private var attemptLimiter = PairingAttemptLimiter()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Gets or generates the pairing code for this device.
    public var pairingCode: String {
        lock.withLock { pairingCodeUnlocked() }
    }

    /// Regenerates the pairing code (invalidates all existing pairings and
    /// device credentials).
    public func regeneratePairingCode() -> String {
        lock.withLock {
            let code = generatePairingCode()
            defaults.set(code, forKey: pairingCodeKey)
            defaults.removeObject(forKey: pairedDevicesKey)
            defaults.removeObject(forKey: credentialsKey)
            // A new code invalidates whatever was being guessed, so the owner
            // can always recover from a lockout by regenerating.
            attemptLimiter.recordSuccess()
            return code
        }
    }

    /// Compares a pairing code in constant time, without counting the attempt.
    ///
    /// Authenticating a peer must go through `attemptPairing(with:)`, which
    /// enforces the failed-attempt lockout.
    public func validatePairingCode(_ code: String) -> Bool {
        lock.withLock { Self.constantTimeEquals(code, pairingCodeUnlocked()) }
    }

    /// Authenticates a peer's pairing code against the server-wide limit.
    ///
    /// While locked out every attempt is refused without being compared, so a
    /// correct guess cannot be confirmed during the window. A success clears
    /// the failure count.
    public func attemptPairing(with code: String, now: Date = Date()) -> PairingAttemptResult {
        attemptPairing(now: now) { Self.constantTimeEquals(code, $0) }
    }

    /// Authenticates a peer that proves knowledge of the code without sending it,
    /// such as the encrypted Send to Mac handshake.
    ///
    /// `proof` receives the current code and reports whether the peer's proof
    /// matches it. It runs under the same limit as `attemptPairing(with:)` and is
    /// not called at all during a lockout.
    public func attemptPairing(now: Date = Date(), provingWith proof: (String) -> Bool) -> PairingAttemptResult {
        lock.withLock { attemptPairingUnlocked(now: now, provingWith: proof) }
    }

    private func attemptPairingUnlocked(now: Date, provingWith proof: (String) -> Bool) -> PairingAttemptResult {
        if let remaining = attemptLimiter.lockoutRemaining(at: now) {
            return .lockedOut(retryAfter: remaining)
        }
        guard proof(pairingCodeUnlocked()) else {
            attemptLimiter.recordFailure(at: now)
            return .rejected
        }
        attemptLimiter.recordSuccess()
        return .accepted
    }

    /// Authenticates the encrypted Send to Mac handshake.
    ///
    /// A proof keyed with a device credential is checked against that credential
    /// alone; an unknown or revoked one is refused without touching the attempt
    /// limit, since nobody can guess a 256-bit secret. A proof keyed with the
    /// code goes through `attemptPairing(provingWith:)`'s limit, and when the
    /// phone asked for one it is issued a new credential in the same
    /// transaction, so a code regenerated meanwhile cannot leave one behind.
    public func authorize(_ proof: TransportPairingProof, now: Date = Date()) -> PairingAttemptResult {
        lock.withLock {
            if let credentialID = proof.credentialID {
                guard let stored = credentialsUnlocked().first(where: { $0.credential.id == credentialID }),
                      proof.verifies(credential: stored.credential) else { return .rejected }
                return .accepted
            }
            let result = attemptPairingUnlocked(now: now, provingWith: proof.verifies(pairingCode:))
            if result == .accepted, proof.requestsCredential {
                let credential = TransportDeviceCredential.generate()
                var stored = credentialsUnlocked()
                stored.append(StoredCredential(credential: credential, deviceId: nil))
                saveCredentialsUnlocked(Array(stored.suffix(Self.maximumCredentials)))
                proof.issue(credential)
            }
            return result
        }
    }

    /// Ties a credential to the device that authenticated with it, so removing
    /// the device revokes the credential too.
    public func bindCredential(_ credentialID: UUID, toDevice deviceId: String) {
        lock.withLock {
            var stored = credentialsUnlocked()
            guard let index = stored.firstIndex(where: { $0.credential.id == credentialID }) else { return }
            stored[index].deviceId = deviceId
            saveCredentialsUnlocked(stored)
        }
    }

    /// Whether `credentialID` is still accepted.
    public func hasCredential(_ credentialID: UUID) -> Bool {
        lock.withLock { credentialsUnlocked().contains { $0.credential.id == credentialID } }
    }

    /// Records a paired device.
    public func addPairedDevice(id: String, name: String) {
        lock.withLock {
            var devices = pairedDevicesUnlocked()
            devices[id] = name
            defaults.set(devices, forKey: pairedDevicesKey)
        }
    }

    /// Removes a paired device and revokes the credentials bound to it.
    public func removePairedDevice(id: String) {
        lock.withLock {
            var devices = pairedDevicesUnlocked()
            devices.removeValue(forKey: id)
            defaults.set(devices, forKey: pairedDevicesKey)
            saveCredentialsUnlocked(credentialsUnlocked().filter { $0.deviceId != id })
        }
    }

    /// Gets all paired devices.
    public var pairedDevices: [String: String] {
        lock.withLock { pairedDevicesUnlocked() }
    }

    /// Checks if a device is paired.
    public func isDevicePaired(id: String) -> Bool {
        lock.withLock { pairedDevicesUnlocked()[id] != nil }
    }

    private func pairingCodeUnlocked() -> String {
        if let existing = defaults.string(forKey: pairingCodeKey) {
            return existing
        }
        let code = generatePairingCode()
        defaults.set(code, forKey: pairingCodeKey)
        return code
    }

    private func pairedDevicesUnlocked() -> [String: String] {
        defaults.dictionary(forKey: pairedDevicesKey) as? [String: String] ?? [:]
    }

    private struct StoredCredential: Codable {
        var credential: TransportDeviceCredential
        var deviceId: String?
    }

    private func credentialsUnlocked() -> [StoredCredential] {
        guard let data = defaults.data(forKey: credentialsKey) else { return [] }
        return (try? JSONDecoder().decode([StoredCredential].self, from: data)) ?? []
    }

    private func saveCredentialsUnlocked(_ credentials: [StoredCredential]) {
        guard !credentials.isEmpty, let data = try? JSONEncoder().encode(credentials) else {
            defaults.removeObject(forKey: credentialsKey)
            return
        }
        defaults.set(data, forKey: credentialsKey)
    }

    private func generatePairingCode() -> String {
        TransportPairingCode.generate()
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        TransportPairingCode.constantTimeEquals(lhs, rhs)
    }
}
