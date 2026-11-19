import Foundation

/// The C loopback listener both desktop hosts export (WindowsNetwork.h and
/// LinuxCloudSync.h declare the same `jsti_loopback_*` contract), as function
/// references. `listen` returns nil and writes `error` on failure; `accept`
/// returns 0 with a connection, 1 once the timeout passes, 3 once cancelled
/// and anything else on failure.
public struct DesktopNativeLoopback: @unchecked Sendable {
    public typealias Handle = OpaquePointer?
    public typealias ErrorBuffer = UnsafeMutablePointer<CChar>?

    /// port, request window (ms), bound port, error, capacity.
    public let listen: (UInt16, Int32, UnsafeMutablePointer<UInt16>?, ErrorBuffer, Int) -> OpaquePointer?
    /// listener, timeout (ms), connection, error, capacity.
    public let accept: (Handle, Int32, UnsafeMutablePointer<OpaquePointer?>?, ErrorBuffer, Int) -> Int32
    public let request: (Handle, UnsafeMutablePointer<Int>?) -> UnsafePointer<UInt8>?
    /// 0 this user's process, 1 another user's, anything else unknown.
    public let peerOwner: (Handle) -> Int32
    public let respond: (Handle, UnsafePointer<UInt8>?, Int) -> Int32
    public let destroyConnection: (Handle) -> Void
    /// Safe from any thread; a blocked `accept` returns 3 promptly.
    public let cancel: (Handle) -> Void
    public let destroy: (Handle) -> Void
    /// The host's error for a native failure message.
    public let failure: @Sendable (String) -> Error

    public init(
        listen: @escaping (UInt16, Int32, UnsafeMutablePointer<UInt16>?, ErrorBuffer, Int) -> OpaquePointer?,
        accept: @escaping (Handle, Int32, UnsafeMutablePointer<OpaquePointer?>?, ErrorBuffer, Int) -> Int32,
        request: @escaping (Handle, UnsafeMutablePointer<Int>?) -> UnsafePointer<UInt8>?,
        peerOwner: @escaping (Handle) -> Int32,
        respond: @escaping (Handle, UnsafePointer<UInt8>?, Int) -> Int32,
        destroyConnection: @escaping (Handle) -> Void,
        cancel: @escaping (Handle) -> Void,
        destroy: @escaping (Handle) -> Void,
        failure: @escaping @Sendable (String) -> Error
    ) {
        self.listen = listen
        self.accept = accept
        self.request = request
        self.peerOwner = peerOwner
        self.respond = respond
        self.destroyConnection = destroyConnection
        self.cancel = cancel
        self.destroy = destroy
        self.failure = failure
    }
}

/// A 127.0.0.1-only HTTP listener over `DesktopNativeLoopback`: the Apple ID
/// sign-in callback, and the loopback fake server in tests. A connection that
/// closes, or sends no complete request within `requestWindow`, is dropped
/// and listening goes on, so an idle browser preconnection cannot hold or end
/// the callback. Each request reports which user's process sent it, so the
/// callback can refuse other accounts on this computer.
public final class DesktopNativeLoopbackListener: DesktopLoopbackListener, @unchecked Sendable {
    public struct Connection: DesktopLoopbackRequest, @unchecked Sendable {
        fileprivate let handle: OpaquePointer
        fileprivate let native: DesktopNativeLoopback

        public var request: Data {
            var count = 0
            guard let bytes = native.request(handle, &count) else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        /// The request line and header fields.
        public var head: DesktopLoopbackRequestHead? { DesktopLoopbackRequestHead(parsing: request) }

        /// Whose process connected, from the OS's TCP tables. Read while the
        /// connection is open, before `respond`.
        public var peer: DesktopLoopbackPeer {
            switch native.peerOwner(handle) {
            case 0: return .currentUser
            case 1: return .otherUser
            default: return .unknown
            }
        }

        /// Writes a complete response and closes the connection.
        public func respond(_ bytes: Data) {
            _ = bytes.withUnsafeBytes {
                native.respond(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
            native.destroyConnection(handle)
        }
    }

    private let native: DesktopNativeLoopback
    private let lock = NSLock()
    private var handle: OpaquePointer?
    public let port: UInt16

    public init(native: DesktopNativeLoopback, port: UInt16 = 0, requestWindow: Duration = .seconds(5)) throws {
        var bound: UInt16 = 0
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = native.listen(port, Self.milliseconds(requestWindow), &bound, &error, error.count) else {
            throw native.failure(String(cString: error))
        }
        self.native = native
        self.handle = handle
        self.port = bound
    }

    /// Waits off the calling thread for one complete request, or returns nil
    /// once `timeout` has passed.
    public func nextRequest(within timeout: Duration) async throws -> Connection? {
        let milliseconds = Self.milliseconds(timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: self.acceptNow(milliseconds))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func acceptNow(_ milliseconds: Int32) -> Result<Connection?, Error> {
        guard let handle = lock.withLock({ handle }) else { return .failure(CancellationError()) }
        var connection: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)
        switch native.accept(handle, milliseconds, &connection, &error, error.count) {
        case 0:
            guard let connection else { return .failure(native.failure("No connection.")) }
            return .success(Connection(handle: connection, native: native))
        case 1: return .success(nil)
        case 3: return .failure(CancellationError())
        default: return .failure(native.failure(String(cString: error)))
        }
    }

    /// Ends a waiting `nextRequest` with `CancellationError`, and every later one.
    public func cancel() {
        lock.withLock { if let handle { native.cancel(handle) } }
    }

    /// Stops listening. Only after every `nextRequest` has returned.
    public func close() {
        lock.withLock {
            if let handle { native.destroy(handle) }
            handle = nil
        }
    }

    deinit { close() }

    static func milliseconds(_ duration: Duration) -> Int32 {
        let (seconds, attoseconds) = duration.components
        let total = seconds.multipliedReportingOverflow(by: 1_000)
        guard !total.overflow else { return seconds < 0 ? 0 : Int32.max }
        return Int32(clamping: max(0, total.partialValue + attoseconds / 1_000_000_000_000_000))
    }
}
