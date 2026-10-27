#if os(iOS)
import Foundation

/// StorageIO fixtures share switches with a serial background worker. Access to
/// the captured value is always locked, including legacy synchronous tests.
final class HistoryTestLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func update(_ operation: (inout Value) -> Void) { lock.withLock { operation(&stored) } }
}
#endif
