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

    /// Regenerates the pairing code (invalidates all existing pairings).
    public func regeneratePairingCode() -> String {
        lock.withLock {
            let code = generatePairingCode()
            defaults.set(code, forKey: pairingCodeKey)
            defaults.removeObject(forKey: pairedDevicesKey)
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
        lock.withLock {
            if let remaining = attemptLimiter.lockoutRemaining(at: now) {
                return .lockedOut(retryAfter: remaining)
            }
            guard Self.constantTimeEquals(code, pairingCodeUnlocked()) else {
                attemptLimiter.recordFailure(at: now)
                return .rejected
            }
            attemptLimiter.recordSuccess()
            return .accepted
        }
    }

    /// Records a paired device.
    public func addPairedDevice(id: String, name: String) {
        lock.withLock {
            var devices = pairedDevicesUnlocked()
            devices[id] = name
            defaults.set(devices, forKey: pairedDevicesKey)
        }
    }

    /// Removes a paired device.
    public func removePairedDevice(id: String) {
        lock.withLock {
            var devices = pairedDevicesUnlocked()
            devices.removeValue(forKey: id)
            defaults.set(devices, forKey: pairedDevicesKey)
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

    private func generatePairingCode() -> String {
        // 6-digit numeric code from the system CSPRNG.
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999999, using: &generator))
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        // The code's length is public (always six digits); only its digits are secret.
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhsBytes, rhsBytes) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

/// Outcome of one pairing-code attempt.
public enum PairingAttemptResult: Equatable, Sendable {
    case accepted
    case rejected
    /// Too many consecutive failures; every attempt is refused until the window ends.
    case lockedOut(retryAfter: TimeInterval)
}

/// Exponential lockout after repeated wrong pairing codes.
///
/// The first `freeFailures` mistakes cost nothing, so a few typos never lock
/// the owner out. After that each further failure doubles the lockout, up to
/// `maximumLockout`, which puts a search of the six-digit space out of reach.
struct PairingAttemptLimiter {
    static let freeFailures = 5
    static let baseLockout: TimeInterval = 30
    static let maximumLockout: TimeInterval = 60 * 60

    private(set) var consecutiveFailures = 0
    private var lockedUntil: Date?

    func lockoutRemaining(at now: Date) -> TimeInterval? {
        guard let lockedUntil, lockedUntil > now else { return nil }
        return lockedUntil.timeIntervalSince(now)
    }

    mutating func recordFailure(at now: Date) {
        consecutiveFailures += 1
        let excess = consecutiveFailures - Self.freeFailures
        guard excess >= 0 else { return }
        let lockout = Self.baseLockout * pow(2, Double(min(excess, 16)))
        lockedUntil = now.addingTimeInterval(min(lockout, Self.maximumLockout))
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        lockedUntil = nil
    }
}
