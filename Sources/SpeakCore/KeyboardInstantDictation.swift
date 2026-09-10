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
    // Kept in its own key rather than inside the session record: the record is
    // schema-versioned and rejected wholesale on a mismatch, and a reason for
    // an ended session has to outlive the session it describes.
    private static let endReasonKey = "keyboardInstantDictation.lastEndReason.v1"

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
            // A live session explains itself; a reason left over from the
            // previous one would not.
            defaults.removeObject(forKey: Self.endReasonKey)
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

    /// Why the most recent readiness session ended, or `nil` when the last one
    /// was ended by the user. Readable from the keyboard process, which never
    /// sees the containing app's in-memory error state (issue #995).
    public var lastEndReason: InstantDictationReadinessEndReason? {
        lock.withLock {
            guard let raw = defaults?.string(forKey: Self.endReasonKey) else { return nil }
            return InstantDictationReadinessEndReason(rawValue: raw)
        }
    }

    /// Records why readiness ended. Passing `nil` clears it, which every
    /// successful start does, so a stale reason can never explain a live
    /// session.
    public func recordEndReason(_ reason: InstantDictationReadinessEndReason?) {
        guard let defaults else { return }
        lock.withLock {
            if let reason {
                defaults.set(reason.rawValue, forKey: Self.endReasonKey)
            } else {
                defaults.removeObject(forKey: Self.endReasonKey)
            }
            defaults.synchronize()
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

/// Payload-free Darwin notifications used only as wake-up hints. Darwin
/// notifications carry no payload at all, so the command, nonce and text stay
/// in the App Group records and are validated there; these say only "look
/// again, now".
///
/// There are two, one per direction:
/// * `requestChanged` — extension → app (issue #712).
/// * `statusChanged` — app → extension (issue #990). Without it the keyboard
///   learned about a phase change or a new interim only on its next poll tick.
public enum KeyboardHandoffSignal {
    // Stored as String (Sendable) and bridged to CFString at each use site,
    // so the shared static needs no concurrency escape hatch.
    private static let requestChangedName = "com.justspeaktoit.keyboardHandoff.requestChanged"
    private static let statusChangedName = "com.justspeaktoit.keyboardHandoff.statusChanged"

    public static func postRequestChanged() {
        post(requestChangedName)
    }

    /// Posted by the containing app after every write the extension is waiting
    /// on: a phase transition, an interim update, or a new pickup offer.
    /// Fire-and-forget — a dropped notification costs only the poll interval,
    /// which is why the safety-net poll remains.
    public static func postStatusChanged() {
        post(statusChangedName)
    }

    public static func observeRequestChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> KeyboardHandoffSignalObservation {
        KeyboardHandoffSignalObservation(name: requestChangedName as CFString, handler: handler)
    }

    public static func observeStatusChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> KeyboardHandoffSignalObservation {
        KeyboardHandoffSignalObservation(name: statusChangedName as CFString, handler: handler)
    }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
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
