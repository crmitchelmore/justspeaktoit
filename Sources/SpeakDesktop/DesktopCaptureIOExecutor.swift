import Dispatch
import Foundation

/// Serial I/O isolation, not OS-thread affinity. COM remains on the native producer thread.
package final class DesktopCaptureIOExecutor: SerialExecutor {
    private let queue: DispatchQueue

    package init() {
        self.queue = DispatchQueue(label: "jsti.owned-capture.\(UUID().uuidString)", qos: .userInitiated)
    }

    package func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}
