import CoreFoundation
import Foundation

/// A user-enabled readiness session in which the containing iOS app stays
/// alive and can service microphone commands from the keyboard immediately.
///
/// The keyboard never records audio. It only reads this liveness record and
/// writes nonce-scoped handoff commands. The containing app refreshes the
/// heartbeat while its foreground-started audio session is alive, preventing a
/// stale preference from making the keyboard promise a microphone that iOS has
/// already suspended. The heartbeat, rather than a fixed timer, is the source
/// of truth: Instant Dictation remains ready until the user turns it off, the
/// app is terminated, or iOS interrupts the audio session.
public struct KeyboardInstantDictationSession: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Phase: String, Codable, Equatable, Sendable {
        case ready
        case recording
    }

    public let schemaVersion: Int
    public let startedAt: Date
    public let lastHeartbeatAt: Date
    public let phase: Phase

    public init(
        schemaVersion: Int = Self.schemaVersion,
        startedAt: Date,
        lastHeartbeatAt: Date,
        phase: Phase
    ) {
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.phase = phase
    }
}

/// App Group-backed preference and liveness state for the containing app's
/// Instant Dictation audio session. Audio and transcript content never enter
/// this store.
/// `@unchecked` only because `UserDefaults` lacks a Sendable annotation in the
/// SDK: all stored properties are immutable references, `UserDefaults` is
/// documented thread-safe, and the `NSLock` serializes every
/// read-modify-write.
public final class KeyboardInstantDictationStore: @unchecked Sendable {
    public static let shared = KeyboardInstantDictationStore()
    public static let heartbeatLifetime: TimeInterval = 4

    private static let sessionKey = "keyboardInstantDictation.session.v1"
    private static let enabledKey = "keyboardInstantDictation.enabled.v1"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: AppGroupAvailability.verifiedDefaults())
    }

    /// Injectable for deterministic tests. Passing `nil` models a missing or
    /// inaccessible App Group.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public var isAvailable: Bool {
        defaults != nil
    }

    public var isEnabled: Bool {
        lock.withLock { isEnabledUnlocked }
    }

    /// Disabling clears any live session in the same locked transaction, so a
    /// concurrent `start()` can neither observe `enabled == false` with a
    /// session still present nor create a fresh session after the clear.
    public func setEnabled(_ enabled: Bool) {
        guard let defaults else { return }
        lock.withLock {
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled {
                clearUnlocked()
            }
            defaults.synchronize()
        }
    }

    /// Creates a readiness session. The enabled check (and, with
    /// `enabling: true`, the enable write itself) happens inside the same lock
    /// as the session write, so `start()` can never race `setEnabled(false)`
    /// into a session that outlives the disable.
    ///
    /// - Parameter enabling: When `true`, atomically turns the preference on
    ///   with the new session — the consent path, where enable + start must be
    ///   one transaction. When `false` (default), returns `nil` while disabled.
    @discardableResult
    public func start(now: Date = Date(), enabling: Bool = false) -> KeyboardInstantDictationSession? {
        guard let defaults else { return nil }
        return lock.withLock {
            if enabling {
                defaults.set(true, forKey: Self.enabledKey)
            } else if !isEnabledUnlocked {
                return nil
            }
            let session = KeyboardInstantDictationSession(
                startedAt: now,
                lastHeartbeatAt: now,
                phase: .ready
            )
            guard writeUnlocked(session) else {
                // Keep "enabled implies a session was created" intact.
                if enabling {
                    defaults.set(false, forKey: Self.enabledKey)
                }
                return nil
            }
            return session
        }
    }

    @discardableResult
    public func heartbeat(
        phase: KeyboardInstantDictationSession.Phase? = nil,
        now: Date = Date()
    ) -> KeyboardInstantDictationSession? {
        lock.withLock {
            guard let current = readUnlocked() else {
                clearUnlocked()
                return nil
            }
            let updated = KeyboardInstantDictationSession(
                startedAt: current.startedAt,
                lastHeartbeatAt: now,
                phase: phase ?? current.phase
            )
            return writeUnlocked(updated) ? updated : nil
        }
    }

    public func activeSession(
        now: Date = Date(),
        clearingStaleRecord: Bool = false
    ) -> KeyboardInstantDictationSession? {
        lock.withLock {
            guard let session = readUnlocked() else { return nil }
            let heartbeatIsFresh = now.timeIntervalSince(session.lastHeartbeatAt) <= Self.heartbeatLifetime
            guard heartbeatIsFresh else {
                if clearingStaleRecord {
                    clearUnlocked()
                }
                return nil
            }
            return session
        }
    }

    public func end() {
        lock.withLock {
            clearUnlocked()
        }
    }

    private var isEnabledUnlocked: Bool {
        defaults?.bool(forKey: Self.enabledKey) ?? false
    }

    private func writeUnlocked(_ session: KeyboardInstantDictationSession) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(session) else { return false }
        defaults.set(data, forKey: Self.sessionKey)
        defaults.synchronize()
        return true
    }

    private func readUnlocked() -> KeyboardInstantDictationSession? {
        guard let data = defaults?.data(forKey: Self.sessionKey),
              let session = try? JSONDecoder().decode(KeyboardInstantDictationSession.self, from: data),
              session.schemaVersion == KeyboardInstantDictationSession.schemaVersion else {
            return nil
        }
        return session
    }

    private func clearUnlocked() {
        defaults?.removeObject(forKey: Self.sessionKey)
        defaults?.synchronize()
    }
}

/// A payload-free Darwin notification used only as a wake-up hint. The actual
/// command and nonce remain in the App Group record and are validated there.
public enum KeyboardHandoffSignal {
    // Stored as String (Sendable) and bridged to CFString at each use site,
    // so the shared static needs no concurrency escape hatch.
    private static let requestChangedName = "com.justspeaktoit.keyboardHandoff.requestChanged"

    public static func postRequestChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(requestChangedName as CFString),
            nil,
            nil,
            true
        )
    }

    public static func observeRequestChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> KeyboardHandoffSignalObservation {
        KeyboardHandoffSignalObservation(name: requestChangedName as CFString, handler: handler)
    }
}

public final class KeyboardHandoffSignalObservation: @unchecked Sendable {
    private let name: CFString
    private let handler: @Sendable () -> Void

    fileprivate init(name: CFString, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let observation = Unmanaged<KeyboardHandoffSignalObservation>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    observation.handler()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name),
            nil
        )
    }
}
