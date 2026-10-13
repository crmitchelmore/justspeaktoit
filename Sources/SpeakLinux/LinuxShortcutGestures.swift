import Foundation
import SpeakCore
import SpeakDesktopHost
import SpeakLinuxPlatform

/// Classifies global shortcut presses and releases (X11 grab or portal
/// Activated/Deactivated) with the shared gesture machine, so hold,
/// double-tap and press-to-toggle follow the macOS session rules. One serial
/// queue owns the machine and its deadline; requests reach the controller one
/// at a time in recognition order, so a release never overtakes its start.
final class LinuxShortcutGestures: @unchecked Sendable {
    typealias Request = DesktopHostShortcutRequest<LinuxHostPlatform>

    private let queue = DispatchQueue(label: "jsti.shortcut-gestures")
    private var machine = HotKeyGestureMachine()
    private var timing = (
        HotKeyGestureTiming.defaultHoldThreshold, HotKeyGestureTiming.defaultDoubleTapWindow
    )
    private var style: HotKeyActivationStyle
    private var target: LinuxInsertionTarget?
    private var textOutput: Task<LinuxTextOutputOptions, Never>?
    private var deadline: DispatchWorkItem?
    private let clock: @Sendable () -> TimeInterval
    private let deliver: @Sendable (Request) async -> Void
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(
        style: HotKeyActivationStyle,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        deliver: @escaping @Sendable (Request) async -> Void
    ) {
        self.style = style
        self.clock = clock
        self.deliver = deliver
    }

    var currentStyle: HotKeyActivationStyle { queue.sync { style } }

    func configureTiming(hold: Double, doubleTap: Double) {
        queue.async { [self] in
            timing = (hold, doubleTap)
        }
    }

    /// A style change forgets partial gestures and ends a hold in progress,
    /// because its release will no longer be reported under the old style.
    func configure(style: HotKeyActivationStyle) {
        queue.async { [self] in
            let ended = machine.reset()
            submit(ended)
            self.style = style
        }
    }

    /// `target` and `textOutput` are captured by the caller at the press.
    func keyDown(target: LinuxInsertionTarget?, textOutput: Task<LinuxTextOutputOptions, Never>) {
        let now = clock()
        queue.async { [self] in
            if !machine.isKeyDown, machine.holdThreshold != timing.0 || machine.doubleTapWindow != timing.1 {
                submit(machine.reset(), at: now)
                machine.holdThreshold = timing.0
                machine.doubleTapWindow = timing.1
            }
            self.target = target
            self.textOutput = textOutput
            if style == .pressToToggle {
                enqueue(.press, at: now)
            } else {
                submit(machine.keyDown(at: now), at: now)
            }
        }
    }

    func keyUp() {
        let now = clock()
        queue.async { [self] in
            guard style != .pressToToggle else { return }
            submit(machine.keyUp(at: now), at: now)
        }
    }

    /// Waits for every request already handed to the controller.
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        await lock.withLock { tail }?.value
    }

    static func checkTimingForSelfTest() async throws {
        let gestures = LinuxShortcutGestures(style: .holdToRecord, clock: { 100 }, deliver: { _ in })
        let output = Task { LinuxTextOutputOptions() }
        gestures.keyDown(target: nil, textOutput: output)
        await gestures.drain()
        gestures.configureTiming(hold: 0.8, doubleTap: 0.7)
        await gestures.drain()
        let preserved = gestures.queue.sync {
            gestures.machine.isKeyDown &&
                gestures.machine.holdThreshold == HotKeyGestureTiming.defaultHoldThreshold
        }
        gestures.keyUp()
        await gestures.drain()
        gestures.keyDown(target: nil, textOutput: output)
        await gestures.drain()
        let applied = gestures.queue.sync {
            gestures.machine.isKeyDown && gestures.machine.holdThreshold == 0.8 &&
                gestures.machine.doubleTapWindow == 0.7
        }
        gestures.configure(style: .pressToToggle)
        await gestures.drain()
        guard preserved, applied else {
            throw DesktopHostError(message: "Shortcut timing interrupted an active gesture or was not applied.")
        }
    }

    // Queue only.
    private func submit(_ gestures: [HotKeyGestureMachine.Gesture], at now: TimeInterval? = nil) {
        let now = now ?? clock()
        deadline?.cancel()
        deadline = nil
        if let next = machine.deadline {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let reached = self.clock()
                self.submit(self.machine.deadlineReached(at: reached), at: reached)
            }
            deadline = work
            queue.asyncAfter(deadline: .now() + max(0, next.time - now), execute: work)
        }
        for gesture in gestures { enqueue(.gesture(gesture), at: now) }
    }

    private func enqueue(_ input: HotKeySessionPolicy.Input, at now: TimeInterval) {
        guard let textOutput else { return }
        let request = Request(
            input: input, style: style, recognisedAt: now, target: target,
            targetExecutablePath: target?.executablePath, textOutput: textOutput, modelIndex: -1, deviceID: ""
        )
        let deliver = deliver
        lock.withLock {
            let previous = tail
            tail = Task {
                await previous?.value
                await deliver(request)
            }
        }
    }
}
