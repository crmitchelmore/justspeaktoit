import Foundation
#if os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum DesktopNativeRetentionIO {
    static func perform<Value>(
        closing close: () throws -> Void, operation: () throws -> Value
    ) throws -> Value {
        let value: Value
        do {
            value = try operation()
        } catch let primary {
            do { try close() } catch {
                throw DesktopNativeRetentionCleanupFailure(primaryError: primary, cleanupError: error)
            }
            throw primary
        }
        // A failed close is terminal: retrying may close an unrelated reused descriptor.
        try close()
        return value
    }

    static func removeStaging(_ file: URL, allowingMissing: Bool = false) throws {
        if allowingMissing, !FileManager.default.fileExists(atPath: file.path) { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        #if os(Windows)
        let native = Array(file.path.utf16) + [0]
        let removed = native.withUnsafeBufferPointer { _wunlink($0.baseAddress) == 0 }
        #else
        let removed = file.path.withCString { unlink($0) == 0 }
        #endif
        guard removed else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

/// Typed diagnostics remain inspectable without exposing underlying paths or values in UI text.
public struct DesktopNativeRetentionCleanupFailure: LocalizedError, Sendable {
    public let primaryError: any Error
    public let cleanupError: any Error
    public var errorDescription: String? {
        "Retained native data processing failed and cleanup also failed. No success was reported."
    }
}
