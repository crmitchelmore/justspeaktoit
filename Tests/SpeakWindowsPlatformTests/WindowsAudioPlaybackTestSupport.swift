#if os(Windows)
import Foundation
import XCTest
@testable import SpeakWindowsPlatform

final class PlaybackTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var enteredValue = false
    var entered: Bool { lock.withLock { enteredValue } }
    func wait() -> Bool {
        lock.withLock { enteredValue = true }
        return semaphore.wait(timeout: .now() + 5) == .success
    }
    func open() { semaphore.signal() }
}

struct PlaybackTestPlan: Sendable {
    var openGate: PlaybackTestGate?
    var startGate: PlaybackTestGate?
    var destroyGate: PlaybackTestGate?
    var completeOnStart: WindowsAudioPlaybackCompletion?
    var startFailure: String?
    var destroyFailures = 0
    var quietOnCancel = true
}

final class PlaybackTestHandle: WindowsAudioPlaybackHandle, @unchecked Sendable {
    struct Counts { var started = 0, paused = 0, resumed = 0, cancelled = 0, destroyed = 0, destroyAttempts = 0 }
    private let lock = NSLock()
    private let completion: @Sendable (WindowsAudioPlaybackCompletion) -> Void
    let plan: PlaybackTestPlan
    private var values = Counts()
    private var value = WindowsAudioPlaybackSnapshot(state: .preparing, position: 0, duration: nil)
    private var completed = false
    private var inStart = false
    private var destroyedInsideStart = false
    private var failuresRemaining: Int

    init(plan: PlaybackTestPlan, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void) {
        self.plan = plan
        self.completion = completion
        self.failuresRemaining = plan.destroyFailures
    }
    var counts: Counts { lock.withLock { values } }
    var destroyedBeforeStartReturn: Bool { lock.withLock { destroyedInsideStart } }
    func set(state: WindowsAudioPlaybackState, position: TimeInterval, duration: TimeInterval? = nil) {
        lock.withLock {
            value = WindowsAudioPlaybackSnapshot(state: state, position: position, duration: duration)
        }
    }
    func acknowledgeQuiet() {
        lock.withLock {
            value = WindowsAudioPlaybackSnapshot(
                state: value.state, position: value.position, duration: value.duration, outputIsQuiet: true
            )
        }
    }
    func start() throws {
        lock.withLock { values.started += 1; inStart = true }
        defer { lock.withLock { inStart = false } }
        if let completion = plan.completeOnStart { complete(completion) }
        if let gate = plan.startGate, !gate.wait() { throw WindowsAudioPlaybackError("Test start gate timed out") }
        if let error = plan.startFailure { throw WindowsAudioPlaybackError(error) }
    }
    func pause() {
        lock.withLock {
            values.paused += 1
            value = WindowsAudioPlaybackSnapshot(state: .paused, position: value.position, duration: value.duration)
        }
    }
    func resume() {
        lock.withLock {
            values.resumed += 1
            value = WindowsAudioPlaybackSnapshot(state: .playing, position: value.position, duration: value.duration)
        }
    }
    func cancel() {
        lock.withLock { values.cancelled += 1 }
        if plan.quietOnCancel { acknowledgeQuiet() }
    }
    func snapshot() -> WindowsAudioPlaybackSnapshot { lock.withLock { value } }
    func complete(_ completion: WindowsAudioPlaybackCompletion) {
        let deliver = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            value = WindowsAudioPlaybackSnapshot(state: .ended, position: completion.played, duration: value.duration)
            return true
        }
        if deliver { self.completion(completion) }
    }
    func destroy() throws {
        lock.withLock { values.destroyAttempts += 1; destroyedInsideStart = destroyedInsideStart || inStart }
        if let gate = plan.destroyGate, !gate.wait() { throw WindowsAudioPlaybackError("Test destroy gate timed out") }
        let fail = lock.withLock { () -> Bool in
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if fail { throw WindowsAudioPlaybackError("Injected release failure") }
        complete(WindowsAudioPlaybackCompletion(status: .cancelled, played: snapshot().position))
        lock.withLock { values.destroyed += 1 }
    }
    func openGates() { plan.openGate?.open(); plan.startGate?.open(); plan.destroyGate?.open() }
}

final class PlaybackTestBackend: WindowsAudioPlaybackBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [PlaybackTestPlan] = []
    private var values: [PlaybackTestHandle] = []
    var handles: [PlaybackTestHandle] { lock.withLock { values } }
    func enqueue(_ plan: PlaybackTestPlan) { lock.withLock { plans.append(plan) } }
    func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle {
        let plan = lock.withLock { plans.isEmpty ? PlaybackTestPlan() : plans.removeFirst() }
        let handle = PlaybackTestHandle(plan: plan, completion: completion)
        lock.withLock { values.append(handle) }
        if let gate = plan.openGate, !gate.wait() { throw WindowsAudioPlaybackError("Test open gate timed out") }
        return handle
    }
    func openAllGates() { handles.forEach { $0.openGates() } }
    func forgetHandles() { lock.withLock { values.removeAll() } }
}

final class PlaybackTestPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WindowsAudioPlaybackDisplay] = []
    private var messages: [WindowsAudioPlaybackStatus] = []
    private var showHook: (@Sendable (WindowsAudioPlaybackDisplay) -> Void)?
    var displays: [WindowsAudioPlaybackDisplay] { lock.withLock { values } }
    var statuses: [String] { lock.withLock { messages.map(\.message) } }
    var notices: [WindowsAudioPlaybackStatus] { lock.withLock { messages } }
    func onShow(_ callback: @escaping @Sendable (WindowsAudioPlaybackDisplay) -> Void) {
        lock.withLock { showHook = callback }
    }
    var presenter: WindowsAudioPlaybackPresenter {
        WindowsAudioPlaybackPresenter(show: { [self] display in
            let hook = lock.withLock { showHook }
            hook?(display)
            lock.withLock { values.append(display) }
        }, status: { [self] status in lock.withLock { messages.append(status) } })
    }
}

final class PlaybackTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

func playbackEventually(
    _ condition: @escaping () -> Bool, _ message: String = "Condition did not become true",
    file: StaticString = #filePath, line: UInt = #line
) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if !condition() { XCTFail(message, file: file, line: line) }
}
#endif
