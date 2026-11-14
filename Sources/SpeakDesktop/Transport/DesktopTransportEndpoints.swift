import Foundation

/// The outcome of one bounded read on a phone connection.
package enum DesktopTransportRead: Equatable {
    case data(Data)
    case timedOut
    case closed
}

/// The outcome of one bounded wait for a new phone connection.
package enum DesktopTransportAccept {
    case connection(any DesktopTransportConnection)
    case timedOut
    case closed
}

/// One accepted TCP connection. Each connection is driven by one thread, so
/// an implementation needs no locking; reads time out so that thread can
/// notice a stop or an expired pairing deadline.
package protocol DesktopTransportConnection: AnyObject {
    func read(maxBytes: Int, timeoutMilliseconds: Int32) -> DesktopTransportRead
    /// Writes every byte, or returns `false` when the connection failed.
    func write(_ data: Data) -> Bool
    func close()
}

/// A TCP listener on every interface. Only its accept thread uses it.
package protocol DesktopTransportListener: AnyObject {
    /// The bound port, which the advertiser publishes.
    var port: UInt16 { get }
    func accept(timeoutMilliseconds: Int32) -> DesktopTransportAccept
    func close()
}

/// Publishes the receiver as a DNS-SD service so the phone can find it.
package protocol DesktopTransportAdvertiser: AnyObject {
    func start(name: String, type: String, port: UInt16) throws
    func stop()
}

/// The native socket and DNS-SD adapters for one platform.
package struct DesktopTransportEndpoints: Sendable {
    package let makeListener: @Sendable () throws -> any DesktopTransportListener
    package let makeAdvertiser: @Sendable () -> any DesktopTransportAdvertiser

    package init(
        makeListener: @escaping @Sendable () throws -> any DesktopTransportListener,
        makeAdvertiser: @escaping @Sendable () -> any DesktopTransportAdvertiser
    ) {
        self.makeListener = makeListener
        self.makeAdvertiser = makeAdvertiser
    }
}

/// A failure the receiver shows on its Settings card.
package struct DesktopTransportError: Error, LocalizedError, Equatable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}
