import Foundation

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

/// The six-digit Send to Mac pairing code, shared by every receiver.
enum TransportPairingCode {
    /// A six-digit numeric code from the system CSPRNG.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0...999_999, using: &generator)
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
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
