#if os(macOS)
import Darwin
import Foundation
import SpeakCore

/// Owns exactly one accepted FD until its read source's cancel handler closes it.
/// No external close races a pending EOF callback or a later reuse of that FD number.
final class AutomationAwaitConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var suspended = false

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
    }

    /// Installed once, before the MainActor response task can finish.
    func observeDisconnect(_ cancel: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: self.descriptor, queue: self.queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let disconnected = self.lock.withLock {
                guard !self.suspended else { return false }
                var byte: UInt8 = 0
                let count = recv(self.descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                guard count >= 0 || (errno != EAGAIN && errno != EINTR) else { return false }
                // EOF is level-triggered: suspend once until the bounded final write/cancel.
                self.source?.suspend()
                self.suspended = true
                return true
            }
            if disconnected { cancel() }
        }
        let descriptor = self.descriptor
        source.setCancelHandler { close(descriptor) }
        self.lock.withLock { self.source = source }
        source.resume()
    }

    func reply(_ response: AutomationResponse) {
        self.queue.async { [self] in
            AutomationServer.send(response, to: self.descriptor)
            self.lock.withLock {
                if self.suspended { self.source?.resume() }
                self.source?.cancel()
                self.source = nil
            }
        }
    }
}
#endif
