import Foundation
import SpeakCore

/// Classifies shortcut presses and releases with the shared gesture machine.
/// Every method runs on the native UI thread, which owns the machine and its
/// one deadline timer. Requests reach the controller one at a time in
/// recognition order, so a release never overtakes the start it ends.
package final class DesktopHostShortcutGestures<Platform: DesktopHostPlatform>: @unchecked Sendable {
    private var machine = HotKeyGestureMachine()
    package private(set) var style: HotKeyActivationStyle = .windowsDefault
    private var target: Platform.InsertionTarget?
    private var textOutput: Task<Platform.TextOutputOptions, Never>?
    private var modelIndex = 0
    private var deviceID = ""
    private let clock: () -> TimeInterval
    private let armDeadline: (Int32) -> Void
    private let executablePath: @Sendable (Platform.InsertionTarget?) -> String?
    private let deliver: @Sendable (DesktopHostShortcutRequest<Platform>) async -> Void
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var timing = (
        HotKeyGestureTiming.defaultHoldThreshold, HotKeyGestureTiming.defaultDoubleTapWindow
    )

    package func configureTiming(hold: Double, doubleTap: Double) {
        lock.withLock { timing = (hold, doubleTap) }
    }

    package init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        armDeadline: @escaping (Int32) -> Void,
        executablePath: @escaping @Sendable (Platform.InsertionTarget?) -> String?,
        deliver: @escaping @Sendable (DesktopHostShortcutRequest<Platform>) async -> Void
    ) {
        self.clock = clock
        self.armDeadline = armDeadline
        self.deliver = deliver
        self.executablePath = executablePath
    }

    /// A style change forgets partial gestures and ends a hold in progress,
    /// because its release will no longer be reported under the old style.
    package func configure(style: HotKeyActivationStyle) {
        let ended = machine.reset()
        armDeadline(-1)
        submit(ended)
        self.style = style
    }

    package func keyDown(
        target: Platform.InsertionTarget?, textOutput: Task<Platform.TextOutputOptions, Never>,
        modelIndex: Int, deviceID: String
    ) {
        let timing = lock.withLock { self.timing }
        if !machine.isKeyDown {
            machine.holdThreshold = timing.0
            machine.doubleTapWindow = timing.1
        }
        self.target = target
        self.textOutput = textOutput
        self.modelIndex = modelIndex
        self.deviceID = deviceID
        submit(machine.keyDown(at: clock()))
    }

    package func keyUp() { submit(machine.keyUp(at: clock())) }

    package func deadlineReached() { submit(machine.deadlineReached(at: clock())) }

    /// Waits for every request already handed to the controller.
    package func drain() async { await lock.withLock { tail }?.value }

    private func submit(_ gestures: [HotKeyGestureMachine.Gesture]) {
        let now = clock()
        if let deadline = machine.deadline {
            let milliseconds = max(0, ((deadline.time - now) * 1_000).rounded(.up))
            armDeadline(Int32(min(milliseconds, Double(Int32.max))))
        } else {
            armDeadline(-1)
        }
        guard let textOutput, !gestures.isEmpty else { return }
        for gesture in gestures {
            let request = DesktopHostShortcutRequest<Platform>(
                input: .gesture(gesture), style: style, recognisedAt: now, target: target,
                targetExecutablePath: executablePath(target), textOutput: textOutput,
                modelIndex: modelIndex, deviceID: deviceID
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
}
