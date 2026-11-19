import Foundation

/// A rejected late registration must close before the next queued registration starts.
package final class DesktopShortcutRegistrationQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    package init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: 1)
    }

    package func submit(_ operation: @escaping @Sendable () -> Void) { queue.async(execute: operation) }

    package func clean(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: key) == 1 { operation() } else { queue.async(execute: operation) }
    }
}
