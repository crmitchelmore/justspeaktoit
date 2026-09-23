import Foundation
import CWindowsSupport

/// Automatic clipboard output for one completed recording whose method is
/// copy to clipboard, whether or not a field was captured. It never inspects
/// focus, inserts or sends input, and places text exactly as the captured-field
/// copy does. Cancellation is native and nonblocking: a cancel that returns
/// before the final check, made while the clipboard is owned, guarantees the
/// clipboard is untouched. The job is destroyed on its last reference, which a
/// running copy retains.
public final class WindowsClipboardOutput: @unchecked Sendable {
    private let handle: OpaquePointer

    public init() throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = jsti_clipboard_output_create(&error, error.count) else {
            throw WindowsTextOutputError(String(cString: error))
        }
        self.handle = handle
    }

    deinit { jsti_clipboard_output_destroy(handle) }

    public func cancel() { jsti_clipboard_output_cancel(handle) }

    /// Blocks for a bounded time; call off the UI thread and actors. A job
    /// copies at most once and refuses after cancellation.
    public func copy(_ text: String) throws {
        // The native text ends at the first NUL; copying only that prefix would
        // report a shortened transcript as copied. Refused before the job runs.
        guard !text.utf8.contains(0) else {
            throw WindowsTextOutputError("The transcript contains a NUL character, so it was not copied.")
        }
        var clipboard: Int32 = 0
        var error = [CChar](repeating: 0, count: 1_024)
        let status = text.withCString { jsti_clipboard_output_copy(handle, $0, &clipboard, &error, error.count) }
        guard status == 0 else {
            throw WindowsTextOutputError(
                String(cString: error), clipboard: WindowsInsertionTarget.ClipboardState(code: clipboard)
            )
        }
    }
}
