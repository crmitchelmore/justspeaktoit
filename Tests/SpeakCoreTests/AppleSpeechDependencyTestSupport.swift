import XCTest

/// Intentionally ignores task cancellation. Tests release it only after asserting waiter recovery.
@MainActor
final class SpeechDependencyGate<Value: Sendable> {
    let entered: XCTestExpectation
    private var continuations: [CheckedContinuation<Value, Never>] = []

    init(_ description: String) {
        entered = XCTestExpectation(description: description)
    }

    func wait() async -> Value {
        await withCheckedContinuation {
            continuations.append($0)
            entered.fulfill()
        }
    }

    func release(_ value: Value) {
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume(returning: value) }
    }
}
