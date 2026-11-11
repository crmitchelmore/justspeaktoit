import Foundation

/// NUL-terminated copies borrowed by one native call. The Windows and Linux
/// presenters build C rows from these; keep the arena alive across the call
/// (`withExtendedLifetime`) and every pointer is freed with it.
public final class DesktopNativeStrings {
    private var owned: [UnsafeMutablePointer<CChar>] = []

    public init() {}

    public func add(_ value: String) -> UnsafePointer<CChar> {
        let bytes = Array(value.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        pointer.initialize(from: bytes, count: bytes.count)
        owned.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit { owned.forEach { $0.deallocate() } }

    /// Writes `message` NUL-terminated into a native error buffer, truncated to fit.
    public static func copy(_ message: String, into buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
        guard let buffer, capacity > 0 else { return }
        let bytes = Array(message.utf8CString.prefix(capacity - 1)) + [0]
        bytes.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: $0.count) }
    }
}
