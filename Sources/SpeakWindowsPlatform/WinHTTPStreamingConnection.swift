import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import CWindowsSupport

/// Windows owns only WebSocket I/O. Provider framing, admission limits and
/// finalisation remain in the same SpeakCore clients used by Apple platforms.
public final class WinHTTPStreamingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let events = WinHTTPEvents()
    private let native: WinHTTPSocket

    public init(request: URLRequest) {
        native = WinHTTPSocket(request: request, events: events)
        events.installAbort { [weak native] in native?.close() }
    }

    public func resume(onOpen: @escaping @Sendable () -> Void) {
        events.installOpen(onOpen)
        native.start()
    }

    public func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        guard events.installSend(completion) else { return }
        native.send(message)
    }

    public func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        events.receive(completion)
    }

    public func cancel() {
        events.fail(CancellationError(), discardPending: true)
        native.close()
    }

    deinit { events.fail(CancellationError(), discardPending: true); native.close() }
}

public struct WinHTTPWebSocketError: LocalizedError, Sendable {
    public let message: String
    public let closeCode: Int32?
    public let closeReason: String?
    public var errorDescription: String? { message }

    init(_ message: String, closeCode: Int32? = nil, closeReason: String? = nil) {
        self.message = message
        self.closeCode = closeCode
        self.closeReason = closeReason
    }
}

/// The C context has its own retained lifetime. Destruction is dispatched away
/// from native callbacks, drains the worker, and only then releases that context.
private final class WinHTTPSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let events: WinHTTPEvents
    private var socket: OpaquePointer?
    private var context: UnsafeMutableRawPointer?
    private var started = false

    init(request: URLRequest, events: WinHTTPEvents) {
        self.events = events
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { $0.deallocate() } }
        func owned(_ value: String) -> UnsafePointer<CChar> {
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
        let names: [UnsafePointer<CChar>?] = headers.map { owned($0.key) }
        let values: [UnsafePointer<CChar>?] = headers.map { owned($0.value) }
        let retained = Unmanaged.passRetained(events).toOpaque()
        var error = [CChar](repeating: 0, count: 1_024)
        socket = names.withUnsafeBufferPointer { names in
            values.withUnsafeBufferPointer { values in
                (request.url?.absoluteString ?? "").withCString { url in
                    jsti_websocket_create(url, names.baseAddress, values.baseAddress, headers.count,
                                          winHTTPEvent, retained, &error, error.count)
                }
            }
        }
        if socket == nil {
            Unmanaged<WinHTTPEvents>.fromOpaque(retained).release()
            events.fail(WinHTTPWebSocketError(String(cString: error)))
        } else { context = retained }
    }

    func start() {
        var failure: Error?
        lock.withLock {
            guard let socket, !started else { return }
            started = true
            var error = [CChar](repeating: 0, count: 1_024)
            if jsti_websocket_start(socket, &error, error.count) != 0 {
                failure = WinHTTPWebSocketError(String(cString: error))
            }
        }
        if let failure { events.fail(failure); close() }
    }

    func send(_ message: StreamingWebSocketMessage) {
        let data: Data
        let isText: Int32
        switch message {
        case .text(let text): data = Data(text.utf8); isText = 1
        case .binary(let bytes): data = bytes; isText = 0
        }
        var failure: Error?
        lock.withLock {
            guard let socket else { failure = CancellationError(); return }
            var error = [CChar](repeating: 0, count: 1_024)
            let result = data.withUnsafeBytes { bytes in
                jsti_websocket_send(socket, bytes.bindMemory(to: UInt8.self).baseAddress,
                                    bytes.count, isText, &error, error.count)
            }
            if result != 0 { failure = WinHTTPWebSocketError(String(cString: error)) }
        }
        if let failure { events.sent(failure) }
    }

    func close() {
        let disposal: WinHTTPDisposal? = lock.withLock {
            guard let socket, let context else { return nil }
            self.socket = nil
            self.context = nil
            jsti_websocket_cancel(socket)
            return WinHTTPDisposal(socket: socket, context: context)
        }
        if let disposal { DispatchQueue.global(qos: .utility).async { disposal.finish() } }
    }
}

private final class WinHTTPDisposal: @unchecked Sendable {
    let socket: OpaquePointer
    let context: UnsafeMutableRawPointer

    init(socket: OpaquePointer, context: UnsafeMutableRawPointer) {
        self.socket = socket
        self.context = context
    }

    func finish() {
        var error = [CChar](repeating: 0, count: 1_024)
        guard jsti_websocket_destroy(socket, &error, error.count) == 0 else {
            // Do not free a callback context while a native worker may use it.
            FileHandle.standardError.write(Data("Windows WebSocket cleanup did not complete.\n".utf8))
            return
        }
        Unmanaged<WinHTTPEvents>.fromOpaque(context).release()
    }
}

private func winHTTPEvent(
    _ event: Int32, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ code: Int32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let events = Unmanaged<WinHTTPEvents>.fromOpaque(context).takeUnretainedValue()
    guard count >= 0, count <= 4 * 1_024 * 1_024, count == 0 || bytes != nil else {
        events.fail(WinHTTPWebSocketError("Windows returned an invalid WebSocket message size.")); return
    }
    let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
    switch event {
    case 1: events.opened()
    case 2:
        guard let text = String(data: data, encoding: .utf8) else {
            events.fail(WinHTTPWebSocketError("The server sent invalid UTF-8 text.")); return
        }
        events.message(.text(text))
    case 3: events.message(.binary(data))
    case 4: events.sent(code == 0 ? nil : WinHTTPWebSocketError("Windows WebSocket send failed (\(code))."))
    case 5:
        events.fail(WinHTTPWebSocketError(
            "The server closed the WebSocket (\(code)).", closeCode: code,
            closeReason: String(data: data, encoding: .utf8)
        ))
    case 6:
        events.fail(WinHTTPWebSocketError(String(data: data, encoding: .utf8) ?? "Windows WebSocket failed."))
    default: events.fail(WinHTTPWebSocketError("Windows returned an unknown WebSocket event."))
    }
}
