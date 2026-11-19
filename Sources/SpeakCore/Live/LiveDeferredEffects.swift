import Foundation

/// Work a lock-guarded live client decides while holding its state lock and
/// performs, in order, once the lock is released. Transport calls, deadlines,
/// host callbacks and continuation resumes therefore never run under the lock,
/// so any of them may re-enter the client, including by starting a
/// replacement session. An effect can run after its run was retired, so every
/// effect that touches a transport re-checks its run first.
struct LiveDeferredEffects {
    private var actions: [() -> Void] = []

    mutating func add(_ action: @escaping () -> Void) { actions.append(action) }

    func perform() { actions.forEach { $0() } }

    /// Runs `change` under `lock`, then performs the effects it recorded.
    static func applying<Value>(under lock: NSLock, _ change: (inout LiveDeferredEffects) -> Value) -> Value {
        var effects = LiveDeferredEffects()
        let value = lock.withLock { change(&effects) }
        effects.perform()
        return value
    }
}
