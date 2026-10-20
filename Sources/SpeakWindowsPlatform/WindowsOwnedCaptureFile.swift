import CWindowsSupport
import Foundation
import SpeakDesktop

/// Explicit qualification entry point, never the shared default or a host route.
/// Uses the existing Windows private-staging ACL policy, not a second policy.
public enum WindowsOwnedCaptureFile {
    public static var qualificationFactory: DesktopOwnedCaptureFile.Factory {
        #if os(Windows)
        .init { try WindowsHeldCaptureWriter(root: $0, directoryID: $1, recordingID: $2) }
        #else
        .init { _, _, _ in throw DesktopOwnedCaptureError.unsupportedPlatform }
        #endif
    }

    /// Explicit native fixture entry point; creates only synthetic UUID children.
    public static func runQualificationFixture(in root: URL) throws {
        #if os(Windows)
        guard root.isFileURL, root.host?.isEmpty != false, root.query == nil, root.fragment == nil,
              !root.path.utf8.contains(0) else { throw DesktopOwnedCaptureError.unsafeDirectory }
        try WindowsHeldCaptureWriter.checked { jsti_owned_capture_file_self_test(root.path, $0, $1) }
        #else
        throw DesktopOwnedCaptureError.unsupportedPlatform
        #endif
    }
}

private final class WindowsHeldCaptureWriter: DesktopOwnedCaptureWriter, @unchecked Sendable {
    let url: URL
    private var native: OpaquePointer?

    init(root: URL, directoryID: UUID, recordingID: UUID) throws {
        guard root.isFileURL, root.host?.isEmpty != false, root.query == nil, root.fragment == nil,
              !root.path.utf8.contains(0) else { throw DesktopOwnedCaptureError.unsafeDirectory }
        self.url = root.appendingPathComponent(directoryID.uuidString, isDirectory: true)
            .appendingPathComponent(recordingID.uuidString + ".wav")
        var created: OpaquePointer?
        try Self.checked {
            jsti_owned_capture_file_create(
                root.path, directoryID.uuidString, recordingID.uuidString, &created, $0, $1
            )
        }
        guard let created else {
            throw NSError(domain: "JSTIWindowsOwnedCapture", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Native capture creation returned no held file."
            ])
        }
        self.native = created
    }

    deinit {
        if let native { jsti_owned_capture_file_destroy(native) }
    }

    func write(_ data: Data) throws {
        let native = try requireOpen()
        try data.withUnsafeBytes { bytes in
            try Self.checked {
                jsti_owned_capture_file_write(
                    native, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, $0, $1
                )
            }
        }
    }

    func seek(toOffset offset: UInt64) throws {
        let native = try requireOpen()
        try Self.checked { jsti_owned_capture_file_seek(native, offset, $0, $1) }
    }

    func synchronize() throws {
        let native = try requireOpen()
        try Self.checked { jsti_owned_capture_file_flush(native, $0, $1) }
    }

    func validateLocation() throws {
        let native = try requireOpen()
        try Self.checked { jsti_owned_capture_file_validate(native, $0, $1) }
    }

    func removeUnpublished() throws {
        let native = try requireOpen()
        try Self.checked { jsti_owned_capture_file_discard(native, $0, $1) }
    }

    func close() throws {
        guard let native else { return }
        self.native = nil
        defer { jsti_owned_capture_file_destroy(native) }
        try Self.checked { jsti_owned_capture_file_close(native, $0, $1) }
    }

    private func requireOpen() throws -> OpaquePointer {
        guard let native else { throw DesktopOwnedCaptureError.closed }
        return native
    }

    fileprivate static func checked(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 1_024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(-1) }
            return action(base, buffer.count)
        }
        guard result == 0 else {
            throw NSError(domain: "JSTIWindowsOwnedCapture", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: String(cString: error)
            ])
        }
    }
}
