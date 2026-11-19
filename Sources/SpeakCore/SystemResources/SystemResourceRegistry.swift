import Foundation

/// A kind of system resource the app can hold on the user's behalf.
public enum SystemResourceKind: String, CaseIterable, Codable, Sendable {
    case microphone
    case audioOutput
    case providerConnection
    case localModel
    case hotKey
    case accessibility
    case keyboardSession
    case backgroundTask
    case liveActivity

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .audioOutput: return "Audio output"
        case .providerConnection: return "Provider connection"
        case .localModel: return "On-device model"
        case .hotKey: return "Hotkey listener"
        case .accessibility: return "Accessibility"
        case .keyboardSession: return "Keyboard session"
        case .backgroundTask: return "Background task"
        case .liveActivity: return "Live Activity"
        }
    }

    /// SF Symbol name; Apple hosts only.
    public var systemImage: String {
        switch self {
        case .microphone: return "mic.fill"
        case .audioOutput: return "speaker.wave.2.fill"
        case .providerConnection: return "network"
        case .localModel: return "cpu"
        case .hotKey: return "keyboard"
        case .accessibility: return "accessibility"
        case .keyboardSession: return "keyboard.badge.ellipsis"
        case .backgroundTask: return "clock.arrow.circlepath"
        case .liveActivity: return "platter.filled.top.iphone"
        }
    }
}

/// One resource the app currently holds: what, why, and since when.
public struct SystemResourceHold: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: SystemResourceKind
    /// Short name of the hold, e.g. "Dictation recording".
    public let title: String
    /// Why it is held, in words a user understands.
    public let reason: String
    /// The component holding it, for diagnostics.
    public let owner: String
    public let since: Date
    /// Optional extra state, e.g. the input device in use.
    public var detail: String?
    /// The release button's label. Nil when the hold cannot be released on its
    /// own (it ends with the hold that owns it, such as a dictation).
    public let releaseTitle: String?
    /// A release was requested and the owner has not ended the hold yet.
    public var isReleasing: Bool

    public var isReleasable: Bool { releaseTitle != nil }
}

/// Ends a hold. Ending is idempotent and also happens when the token is
/// deallocated, so an owner that is torn down can never leave a stale row.
public final class SystemResourceToken: @unchecked Sendable {
    public let id: UUID
    private weak var registry: SystemResourceRegistry?

    fileprivate init(id: UUID, registry: SystemResourceRegistry) {
        self.id = id
        self.registry = registry
    }

    deinit {
        registry?.end(id)
    }

    public func end() {
        registry?.end(id)
    }

    public func update(detail: String?) {
        registry?.update(id, detail: detail)
    }
}

/// Cancels a ``SystemResourceRegistry/observe(_:)`` registration, also on deinit.
public final class SystemResourceObservation: @unchecked Sendable {
    private let cancelAction: () -> Void
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(cancel: @escaping () -> Void) {
        self.cancelAction = cancel
    }

    deinit { cancel() }

    public func cancel() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        lock.unlock()
        if !alreadyCancelled { cancelAction() }
    }
}

/// The one place every component records the system resources it holds
/// (issue #1471), so a Status view can show what the app holds, why and since
/// when, and release any of it.
///
/// Owners call ``acquire(kind:title:reason:owner:detail:releaseTitle:release:)``
/// when they take a resource and end the returned token when they let it go.
/// A release action only *asks* the owner to stop: the hold stays listed until
/// the owner ends its token, so a release that does not work stays visible.
public final class SystemResourceRegistry: @unchecked Sendable {
    public typealias Release = @Sendable () async -> Void

    public static let shared = SystemResourceRegistry()

    private struct Entry {
        var hold: SystemResourceHold
        let release: Release?
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var entries: [UUID: Entry] = [:]
    private var observers: [UUID: @Sendable ([SystemResourceHold]) -> Void] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Records a hold. Keep the token for as long as the resource is held.
    public func acquire(
        kind: SystemResourceKind,
        title: String,
        reason: String,
        owner: String,
        detail: String? = nil,
        releaseTitle: String? = "Release",
        release: Release? = nil
    ) -> SystemResourceToken {
        let id = UUID()
        let hold = SystemResourceHold(
            id: id, kind: kind, title: title, reason: reason, owner: owner, since: now(), detail: detail,
            releaseTitle: release == nil ? nil : releaseTitle, isReleasing: false
        )
        mutate { $0[id] = Entry(hold: hold, release: release) }
        return SystemResourceToken(id: id, registry: self)
    }

    /// Every current hold, oldest first.
    public var holds: [SystemResourceHold] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sorted(entries)
    }

    public func holds(of kind: SystemResourceKind) -> [SystemResourceHold] {
        holds.filter { $0.kind == kind }
    }

    /// Asks the owner of `id` to release it. Returns false when the hold is
    /// gone, cannot be released or is already being released.
    @discardableResult
    public func release(_ id: UUID) async -> Bool {
        var action: Release?
        mutate { entries in
            guard var entry = entries[id], let release = entry.release, !entry.hold.isReleasing else { return }
            entry.hold.isReleasing = true
            entries[id] = entry
            action = release
        }
        guard let action else { return false }
        await action()
        // The owner normally ended the hold. If it did not, show the button
        // again so the user can retry instead of facing a stuck spinner.
        mutate { entries in
            guard var entry = entries[id] else { return }
            entry.hold.isReleasing = false
            entries[id] = entry
        }
        return true
    }

    /// Releases every releasable hold, optionally only of `kinds`. Returns how
    /// many releases ran.
    @discardableResult
    public func releaseAll(kinds: Set<SystemResourceKind>? = nil) async -> Int {
        let targets = holds.filter { $0.isReleasable && (kinds?.contains($0.kind) ?? true) }
        var released = 0
        for hold in targets where await release(hold.id) {
            released += 1
        }
        return released
    }

    /// Calls `handler` with the current holds now and after every change, on
    /// the thread that made the change.
    public func observe(_ handler: @escaping @Sendable ([SystemResourceHold]) -> Void) -> SystemResourceObservation {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        let snapshot = Self.sorted(entries)
        lock.unlock()
        handler(snapshot)
        return SystemResourceObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[id] = nil
            self.lock.unlock()
        }
    }

    fileprivate func end(_ id: UUID) {
        mutate { $0[id] = nil }
    }

    fileprivate func update(_ id: UUID, detail: String?) {
        mutate { entries in
            guard var entry = entries[id], entry.hold.detail != detail else { return }
            entry.hold.detail = detail
            entries[id] = entry
        }
    }

    private func mutate(_ change: (inout [UUID: Entry]) -> Void) {
        lock.lock()
        let before = entries.mapValues(\.hold)
        change(&entries)
        let changed = entries.mapValues(\.hold) != before
        let snapshot = changed ? Self.sorted(entries) : []
        let handlers = changed ? Array(observers.values) : []
        lock.unlock()
        for handler in handlers {
            handler(snapshot)
        }
    }

    private static func sorted(_ entries: [UUID: Entry]) -> [SystemResourceHold] {
        entries.values.map(\.hold).sorted {
            $0.since == $1.since ? $0.id.uuidString < $1.id.uuidString : $0.since < $1.since
        }
    }
}
