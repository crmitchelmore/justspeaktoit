import CoreFoundation
import Foundation

/// A short, explicitly-started window in which the containing iOS app is
/// alive and ready to service microphone commands from the keyboard.
///
/// The keyboard never records audio. It only reads this liveness record and
/// writes nonce-scoped handoff commands. The containing app refreshes the
/// heartbeat while its foreground-started audio session is alive, preventing a
/// stale `expiresAt` value from making the keyboard promise a microphone that
/// iOS has already suspended.
public struct KeyboardQuickDictationSession: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Phase: String, Codable, Equatable, Sendable {
        case ready
        case recording
    }

    public let schemaVersion: Int
    public let startedAt: Date
    public let expiresAt: Date
    public let lastHeartbeatAt: Date
    public let phase: Phase

    public init(
        schemaVersion: Int = Self.schemaVersion,
        startedAt: Date,
        expiresAt: Date,
        lastHeartbeatAt: Date,
        phase: Phase
    ) {
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.phase = phase
    }
}

/// App Group-backed liveness state for the containing app's prepared audio
/// session. Audio and transcript content never enter this store.
public final class KeyboardQuickDictationStore {
    public static let shared = KeyboardQuickDictationStore()
    public static let defaultDuration: TimeInterval = 5 * 60
    public static let heartbeatLifetime: TimeInterval = 4

    private static let sessionKey = "keyboardQuickDictation.session.v1"

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: KeyboardHandoffStore.appGroupIdentifier))
    }

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    @discardableResult
    public func start(
        now: Date = Date(),
        duration: TimeInterval = defaultDuration
    ) -> KeyboardQuickDictationSession? {
        lock.withLock {
            guard duration > 0 else { return nil }
            let session = KeyboardQuickDictationSession(
                startedAt: now,
                expiresAt: now.addingTimeInterval(duration),
                lastHeartbeatAt: now,
                phase: .ready
            )
            return writeUnlocked(session) ? session : nil
        }
    }

    @discardableResult
    public func heartbeat(
        phase: KeyboardQuickDictationSession.Phase? = nil,
        now: Date = Date()
    ) -> KeyboardQuickDictationSession? {
        lock.withLock {
            guard let current = readUnlocked(),
                  current.phase == .recording || current.expiresAt > now else {
                clearUnlocked()
                return nil
            }
            let updated = KeyboardQuickDictationSession(
                startedAt: current.startedAt,
                expiresAt: current.expiresAt,
                lastHeartbeatAt: now,
                phase: phase ?? current.phase
            )
            return writeUnlocked(updated) ? updated : nil
        }
    }

    public func activeSession(
        now: Date = Date(),
        clearingStaleRecord: Bool = false
    ) -> KeyboardQuickDictationSession? {
        lock.withLock {
            guard let session = readUnlocked() else { return nil }
            let heartbeatIsFresh = now.timeIntervalSince(session.lastHeartbeatAt) <= Self.heartbeatLifetime
            let readinessWindowIsOpen = session.phase == .recording || session.expiresAt > now
            guard heartbeatIsFresh, readinessWindowIsOpen else {
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

    private func writeUnlocked(_ session: KeyboardQuickDictationSession) -> Bool {
        guard let defaults, let data = try? encoder.encode(session) else { return false }
        defaults.set(data, forKey: Self.sessionKey)
        defaults.synchronize()
        return true
    }

    private func readUnlocked() -> KeyboardQuickDictationSession? {
        guard let data = defaults?.data(forKey: Self.sessionKey),
              let session = try? decoder.decode(KeyboardQuickDictationSession.self, from: data),
              session.schemaVersion == KeyboardQuickDictationSession.schemaVersion else {
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
    private static let requestChangedName = "com.justspeaktoit.keyboardHandoff.requestChanged" as CFString

    public static func postRequestChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(requestChangedName),
            nil,
            nil,
            true
        )
    }

    public static func observeRequestChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> KeyboardHandoffSignalObservation {
        KeyboardHandoffSignalObservation(name: requestChangedName, handler: handler)
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
