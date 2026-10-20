import Foundation
import CLinuxSupport

/// A selection-only invocation receipt; it has no insertion or correction API.
public final class LinuxSelectedTextTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    private init(_ handle: OpaquePointer) { self.handle = handle }

    deinit {
        if let handle { jsti_atspi_selection_release(handle) }
    }

    public static func captureAdmitted() -> LinuxSelectedTextTarget? {
        jsti_atspi_selection_capture().map { LinuxSelectedTextTarget($0) }
    }

    public static func stopSessionAccess() {
        _ = jsti_atspi_selection_consent(0, 0)
    }

    public static var availability: String {
        switch jsti_atspi_selection_status() {
        case 0: return "Allow selected-text access in Voice Output for this session first."
        case 1: return "Selection access is connecting. Refocus the external field before trying again."
        case 2: return "No fresh selection target is available, or a read is already pending. "
            + "Refocus an ordinary editable AT-SPI field, select text and try again."
        case 4: return "Selection access stopped because AT-SPI cleanup failed. Stop access and allow it again."
        case 5: return "The installed AT-SPI registry has an unsupported cleanup contract. No text was read."
        default: return "AT-SPI is unavailable or disabled. No desktop accessibility setting was changed."
        }
    }

    public func selectedText() async throws -> String {
        try Task.checkCancellation()
        let text = try await Task.detached { try self.consume() }.value
        try Task.checkCancellation()
        return text
    }

    private func consume() throws -> String {
        guard let handle = lock.withLock({ () -> OpaquePointer? in
            defer { self.handle = nil }
            return self.handle
        }) else {
            throw LinuxNativeError(message: "This selected-text request has already been consumed.")
        }
        defer { jsti_atspi_selection_release(handle) }
        var bytes = [CChar](repeating: 0, count: 32769)
        guard jsti_atspi_selection_read(handle, &bytes, bytes.count) == 1 else {
            throw LinuxNativeError(message: "Selected text could not be read safely. Access, focus, selection "
                + "or privacy state changed, the request expired, or the field is unsupported. No speech was sent.")
        }
        return String(cString: bytes)
    }
}
