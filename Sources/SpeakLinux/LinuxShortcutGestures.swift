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
