import Foundation
import CLinuxSupport

/// A failure reported by the native Linux adapter, shown verbatim.
public struct LinuxNativeError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

public enum LinuxNative {
    /// Calls a `jsti_*` function that writes its failure into a buffer.
    /// Returns its status when that is 0 or listed in `accepting`.
    @discardableResult
    public static func checked(
        accepting: Set<Int32> = [], _ action: (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws -> Int32 {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = action(&buffer, buffer.count)
        guard result == 0 || accepting.contains(result) else {
            throw LinuxNativeError(message: String(cString: buffer))
        }
        return result
    }

    /// Calls a `jsti_*` function that must return 0.
    public static func call(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        _ = try checked(action)
    }
}
