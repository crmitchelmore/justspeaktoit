#if canImport(Glibc) || canImport(Darwin)
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// File-level wrappers, because the transport methods share the C names.
private func systemAccept(_ descriptor: Int32) -> Int32 { accept(descriptor, nil, nil) }
private func systemClose(_ descriptor: Int32) { _ = close(descriptor) }
private func systemReceive(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    recv(descriptor, buffer, count, 0)
}

private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
    #else
    send(descriptor, buffer, count, 0)
    #endif
}

private let streamSocket: Int32 = {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}()

private func setOption(_ descriptor: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
    var value = value
    _ = setsockopt(descriptor, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
}

private func waitReadable(_ descriptor: Int32, timeoutMilliseconds: Int32) -> Int32 {
    var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return poll(&pending, 1, timeoutMilliseconds)
}

/// A blocking POSIX TCP connection with bounded reads.
package final class DesktopPOSIXTransportConnection: DesktopTransportConnection {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
        #if canImport(Darwin)
        setOption(descriptor, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        setOption(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, 1)
        var timeout = timeval()
        timeout.tv_sec = 5
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    /// A client connection to `127.0.0.1:port`, for loopback tests.
    package static func connect(toLoopbackPort port: UInt16) throws -> DesktopPOSIXTransportConnection {
        let descriptor = socket(AF_INET, streamSocket, 0)
        guard descriptor >= 0 else { throw DesktopTransportError("socket failed (\(errno))") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glue.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let failure = errno
            systemClose(descriptor)
            throw DesktopTransportError("connect failed (\(failure))")
        }
        return DesktopPOSIXTransportConnection(descriptor: descriptor)
    }

    package func read(maxBytes: Int, timeoutMilliseconds: Int32) -> DesktopTransportRead {
        guard descriptor >= 0 else { return .closed }
        let ready = waitReadable(descriptor, timeoutMilliseconds: timeoutMilliseconds)
        if ready == 0 || (ready < 0 && errno == EINTR) { return .timedOut }
        guard ready > 0 else { return .closed }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes { systemReceive(descriptor, $0.baseAddress!, maxBytes) }
        if count > 0 { return .data(Data(buffer[0..<count])) }
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
        return .closed
    }

    package func write(_ data: Data) -> Bool {
        guard descriptor >= 0 else { return false }
        var offset = 0
        let bytes = Array(data)
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes {
                systemSend(descriptor, $0.baseAddress! + offset, bytes.count - offset)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }

    /// Half-closes, drains briefly so the peer reads the last frames rather
    /// than a reset, then closes.
    package func close() {
        guard descriptor >= 0 else { return }
        _ = shutdown(descriptor, Int32(SHUT_WR))
        var scratch = [UInt8](repeating: 0, count: 512)
        let drainUntil = Date().addingTimeInterval(0.2)
        while Date() < drainUntil, waitReadable(descriptor, timeoutMilliseconds: 50) > 0 {
            let count = scratch.withUnsafeMutableBytes { systemReceive(descriptor, $0.baseAddress!, 512) }
            if count <= 0 { break }
        }
        systemClose(descriptor)
        descriptor = -1
    }
}

/// A POSIX TCP listener on an ephemeral port: dual-stack on every interface,
/// or IPv4 only when IPv6 is unavailable, or loopback only for tests.
package final class DesktopPOSIXTransportListener: DesktopTransportListener {
    private var descriptor: Int32
    package let port: UInt16

    package init(loopbackOnly: Bool = false) throws {
        let bound = loopbackOnly ? nil : Self.bindDualStack()
        guard let socket = try bound ?? Self.bindIPv4(loopbackOnly: loopbackOnly) else {
            throw DesktopTransportError("no network socket is available")
        }
        descriptor = socket.0
        port = socket.1
    }

    deinit { close() }

    package func accept(timeoutMilliseconds: Int32) -> DesktopTransportAccept {
        guard descriptor >= 0 else { return .closed }
        let ready = waitReadable(descriptor, timeoutMilliseconds: timeoutMilliseconds)
        if ready == 0 || (ready < 0 && errno == EINTR) { return .timedOut }
        guard ready > 0 else { return .closed }
        let client = systemAccept(descriptor)
        if client >= 0 { return .connection(DesktopPOSIXTransportConnection(descriptor: client)) }
        switch errno {
        case EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED, EMFILE, ENFILE: return .timedOut
        default: return .closed
        }
    }

    package func close() {
        guard descriptor >= 0 else { return }
        systemClose(descriptor)
        descriptor = -1
    }

    private static func bindDualStack() -> (Int32, UInt16)? {
        let descriptor = socket(AF_INET6, streamSocket, 0)
        guard descriptor >= 0 else { return nil }
        setOption(descriptor, Int32(IPPROTO_IPV6), IPV6_V6ONLY, 0)
        var address = sockaddr_in6()
        #if canImport(Darwin)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        return finish(descriptor, address: &address)
    }

    private static func bindIPv4(loopbackOnly: Bool) throws -> (Int32, UInt16)? {
        let descriptor = socket(AF_INET, streamSocket, 0)
        guard descriptor >= 0 else { throw DesktopTransportError("socket failed (\(errno))") }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = (loopbackOnly ? UInt32(0x7F00_0001) : 0).bigEndian
        guard let bound = finish(descriptor, address: &address) else {
            throw DesktopTransportError("could not open a listening port (\(errno))")
        }
        return bound
    }

    /// Binds to an ephemeral port, listens, and reads the port back.
    private static func finish<Address>(_ descriptor: Int32, address: inout Address) -> (Int32, UInt16)? {
        let size = socklen_t(MemoryLayout<Address>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            systemClose(descriptor)
            return nil
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            systemClose(descriptor)
            return nil
        }
        let port = withUnsafePointer(to: &storage) { pointer -> UInt16 in
            if Int32(pointer.pointee.ss_family) == AF_INET6 {
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            }
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt16(bigEndian: $0.pointee.sin_port)
            }
        }
        return (descriptor, port)
    }
}

private enum Glue {
    static func connect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.connect(descriptor, address, length)
        #else
        Darwin.connect(descriptor, address, length)
        #endif
    }
}
#endif
