import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns a duplicated stdout FD. External FileHandle closure cannot reuse this FD while flags restore.
/// The dispatcher serializes calls. EOF cancels before its output boundary; an already-admitted write
/// may finish during close, but none can occur after close returns. A partial/broken frame ends dispatch.
final class MCPBoundedOutput {
    #if canImport(Darwin)
    private let descriptor: Int32

    init(output: FileHandle) {
        self.descriptor = dup(output.fileDescriptor)
        if self.descriptor >= 0 { _ = fcntl(self.descriptor, F_SETNOSIGPIPE, 1) }
    }

    deinit { if self.descriptor >= 0 { close(self.descriptor) } }

    func write(_ data: Data, isClosed: () -> Bool, didBackpressure: () -> Void = {}) -> Bool {
        guard self.descriptor >= 0 else { return false }
        let flags = fcntl(self.descriptor, F_GETFL)
        guard flags >= 0, fcntl(self.descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(self.descriptor, F_SETFL, flags) }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            var reportedBackpressure = false
            while offset < data.count {
                guard !isClosed(), ContinuousClock().now < deadline else { return false }
                let count = Darwin.write(self.descriptor, base.advanced(by: offset), data.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                if !reportedBackpressure { reportedBackpressure = true; didBackpressure() }
                var pending = pollfd(fd: self.descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pending, 1, 25)
            }
            return true
        }
    }
    #else
    // Named-capture await is unsupported by the non-Mac app host. Preserve its existing output path.
    private let output: FileHandle
    init(output: FileHandle) { self.output = output }
    func write(_ data: Data, isClosed: () -> Bool) -> Bool {
        guard !isClosed() else { return false }
        self.output.write(data)
        return true
    }
    #endif
}
