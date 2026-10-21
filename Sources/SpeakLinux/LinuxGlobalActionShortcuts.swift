import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

final class LinuxGlobalActionShortcuts: @unchecked Sendable {
    private let transitions = NSLock()
    private let lock = NSLock()
    private let worker = DesktopShortcutRegistrationQueue(label: "jsti.linux-global-actions")
    private var started = false
    private var stopped = false
    private var bindings: DesktopShortcutBindings?
    private var lifetime: DesktopShortcutListenerLifetime?
    private var notes: [DesktopShortcutAction: String] = [:]
    private var listenerFailed = false

    func notes(for bindings: DesktopShortcutBindings) -> [DesktopShortcutAction: String] {
        lock.withLock { self.bindings == bindings ? notes : [:] }
    }

    func start(_ holder: LinuxEventContext) {
        guard LinuxHostPlatform.session.displayServer == .x11 else { return }
        transitions.withLock {
            let saved: DesktopShortcutBindings? = lock.withLock {
                guard !started, !stopped else { return nil }
                started = true
                return bindings ?? .defaults
            }
            if let saved { request(saved, holder: holder, force: true) }
        }
    }

    func configure(_ value: DesktopShortcutBindings, holder: LinuxEventContext) {
        guard LinuxHostPlatform.session.displayServer == .x11 else { return }
        transitions.withLock { request(value, holder: holder, force: false) }
    }

    private func request(_ value: DesktopShortcutBindings, holder: LinuxEventContext, force: Bool) {
        let plan = DesktopLinuxGlobalShortcutPlan(
            bindings: value,
            runnable: Set(DesktopShortcutAction.allCases.filter {
                LinuxActionShortcutRun($0).supportsAutomaticGlobalRegistration
            }),
            dictation: .init(keysym: LinuxShortcuts.x11Keysym, modifiers: LinuxShortcuts.x11Modifiers)
        )
        let next = DesktopShortcutListenerLifetime()
        var prior: DesktopShortcutListenerLifetime?
        let shouldRegister = lock.withLock {
            guard !stopped, force || bindings != value else { return false }
            bindings = value
            prior = lifetime
            lifetime = nil
            notes = plan.refusals
            listenerFailed = false
            guard started else { return false }
            lifetime = next
            for entry in plan.entries { notes[entry.action] = "Checking X11 shortcut availability..." }
            return next.begin()
        }
        prior?.stop()
        guard shouldRegister else { return }
        let callback = LinuxGlobalActionCallback(holder: holder, lifetime: next, entries: plan.entries, owner: self)
        worker.submit { [self] in self.register(plan, bindings: value, lifetime: next, callback: callback) }
    }

    /// Stop fences immediately; an in-flight native registration owns its late cleanup.
    func stop() {
        transitions.withLock {
            let prior: DesktopShortcutListenerLifetime? = lock.withLock {
                stopped = true
                let prior = lifetime
                lifetime = nil
                return prior
            }
            prior?.stop()
        }
    }

    func lost(_ source: DesktopShortcutListenerLifetime, callback: LinuxGlobalActionCallback) {
        source.admitCallback {
            let accepted = lock.withLock {
                guard lifetime === source, !stopped else { return false }
                listenerFailed = true
                for action in Array(notes.keys) {
                    notes[action] = "X11 listener stopped. Use desktop keyboard settings or reopen the app."
                }
                return true
            }
            if accepted {
                LinuxHostPlatform.update("The X11 global action listener stopped. Use desktop keyboard settings.")
                callback.refresh()
            }
        }
    }

    private func register(
        _ plan: DesktopLinuxGlobalShortcutPlan, bindings: DesktopShortcutBindings,
        lifetime: DesktopShortcutListenerLifetime, callback: LinuxGlobalActionCallback
    ) {
        guard lifetime.acceptsCallbacks else { return }
        var result = plan.refusals
        var cleanup: (@Sendable () -> Void)?
        do {
            if !plan.entries.isEmpty {
                let registration = try LinuxNativeActionGroup(plan.entries, callback: callback)
                for (index, entry) in plan.entries.enumerated() {
                    do {
                        try registration.result(index)
                        result[entry.action] = "All apps (X11). \(entry.chord.displayName)"
                    } catch {
                        result[entry.action] = "Not registered: \(error.localizedDescription)"
                    }
                }
                let worker = self.worker
                cleanup = { worker.clean { registration.close() } }
            }
        } catch {
            for entry in plan.entries { result[entry.action] = "Not registered: \(error.localizedDescription)" }
        }
        guard lifetime.finish(cleanup: cleanup) else { return }
        lifetime.publish {
            lock.withLock {
                guard self.bindings == bindings, self.lifetime === lifetime, !stopped else { return }
                if listenerFailed {
                    for entry in plan.entries {
                        result[entry.action] = "X11 listener stopped. Use desktop keyboard settings or reopen the app."
                    }
                }
                notes = result
            }
            callback.refresh()
        }
    }
}

private final class LinuxNativeActionGroup: @unchecked Sendable {
    private let handle: OpaquePointer
    private let callback: LinuxGlobalActionCallback

    init(_ entries: [DesktopLinuxGlobalShortcutPlan.Entry], callback: LinuxGlobalActionCallback) throws {
        self.callback = callback
        let rows = entries.map {
            JSTIX11ActionShortcut(keysym: $0.chord.keysym, modifiers: $0.chord.modifiers, identifier: $0.identifier)
        }
        var handle: OpaquePointer?
        try LinuxNative.call { error, capacity in
            handle = rows.withUnsafeBufferPointer {
                jsti_x11_action_shortcuts_start(
                    $0.baseAddress, $0.count, linuxGlobalActionPressed,
                    Unmanaged.passUnretained(callback).toOpaque(), error, capacity
                )
            }
            return handle == nil ? -1 : 0
        }
        guard let handle else { throw DesktopHostError(message: "X11 returned no action shortcut listener.") }
        self.handle = handle
    }

    func result(_ row: Int) throws {
        try LinuxNative.call { jsti_x11_action_shortcuts_result(handle, row, $0, $1) }
    }

    func close() { withExtendedLifetime(callback) { jsti_x11_action_shortcuts_stop(handle) } }
}
