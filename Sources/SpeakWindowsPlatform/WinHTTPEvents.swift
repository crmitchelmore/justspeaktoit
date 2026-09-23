import Foundation
import SpeakCore

/// The native worker may produce a response just before the consumer asks for
/// it. Buffer complete messages with explicit byte and count bounds, and invoke
/// callbacks outside the lock so provider code can re-enter or cancel safely.
final class WinHTTPEvents: @unchecked Sendable {
    typealias Receiver = @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void
    private struct CompletionCallbacks {
        var receiver: Receiver?
        var sender: (@Sendable (Error?) -> Void)?
        var abort: (@Sendable () -> Void)?
    }
    private let lock = NSLock()
    private var onOpen: (@Sendable () -> Void)?
    private var sender: (@Sendable (Error?) -> Void)?
    private var receiver: Receiver?
    private var messages: [StreamingWebSocketMessage] = []
    private var queuedBytes = 0
    private var terminal: Error?
    private var abort: (@Sendable () -> Void)?

    func installAbort(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { abort = callback }
    }

    func installOpen(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { if terminal == nil { onOpen = callback } }
    }

    func opened() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onOpen = nil }
            return terminal == nil ? onOpen : nil
        }
        callback?()
    }

    func installSend(_ completion: @escaping @Sendable (Error?) -> Void) -> Bool {
        let error: Error? = lock.withLock {
            if let terminal { return terminal }
            guard sender == nil else { return WinHTTPWebSocketError("A WebSocket send is already in progress.") }
            sender = completion
            return nil
        }
        if let error { completion(error); return false }
        return true
    }

    func sent(_ error: Error?) {
        let callback = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            defer { sender = nil }
            return sender
        }
        callback?(error)
    }

    func receive(_ completion: @escaping Receiver) {
        let result: Result<StreamingWebSocketMessage, Error>? = lock.withLock {
            if !messages.isEmpty {
                let message = messages.removeFirst()
                queuedBytes -= Self.size(message)
                return .success(message)
            }
            if let terminal { return .failure(terminal) }
            guard receiver == nil else {
                return .failure(WinHTTPWebSocketError("A WebSocket receive is already in progress."))
            }
            receiver = completion
            return nil
        }
        if let result { completion(result) }
    }

    func message(_ message: StreamingWebSocketMessage) {
        var overflow = false
        let callback: Receiver? = lock.withLock {
            guard terminal == nil else { return nil }
            if let callback = receiver { receiver = nil; return callback }
            let size = Self.size(message)
            guard messages.count < 64, size <= 4 * 1_024 * 1_024 - queuedBytes else {
                overflow = true
                return nil
            }
            messages.append(message)
            queuedBytes += size
            return nil
        }
        callback?(.success(message))
        if overflow {
            let error = WinHTTPWebSocketError("The WebSocket consumer could not keep up with the server.")
            fail(error, discardPending: true)
        }
    }

    func fail(_ error: Error, discardPending: Bool = false) {
        let callbacks = lock.withLock { () -> CompletionCallbacks in
            if discardPending { messages.removeAll(); queuedBytes = 0 }
            guard terminal == nil else { return CompletionCallbacks() }
            terminal = error
            onOpen = nil
            let callbacks = CompletionCallbacks(receiver: receiver, sender: sender, abort: abort)
            receiver = nil
            sender = nil
            abort = nil
            return callbacks
        }
        callbacks.receiver?(.failure(error))
        callbacks.sender?(error)
        callbacks.abort?()
    }

    private static func size(_ message: StreamingWebSocketMessage) -> Int {
        switch message {
        case .text(let text): return text.utf8.count
        case .binary(let data): return data.count
        }
    }
}
