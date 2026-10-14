import CWindowsSupport
import SpeakDesktop

public enum WindowsClipboardRead {
    public static func readText() async throws -> String? {
        try Task.checkCancellation()
        return try await DesktopNativeClipboardRead.read(WindowsClipboardReadRequest())
    }
}

private final class WindowsClipboardReadRequest: DesktopNativeClipboardReadRequest, @unchecked Sendable {
    private let handle: OpaquePointer

    init() throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let handle = jsti_windows_clipboard_read_create(
            DesktopClipboardVoiceCommands.maximumClipboardUTF8Bytes,
            DesktopNativeClipboardRead.timeoutMilliseconds, &error, error.count
        ) else { throw DesktopClipboardReadError.nativeFailure(String(cString: error)) }
        self.handle = handle
    }

    deinit { jsti_windows_clipboard_read_destroy(handle) }

    func run() throws -> String? {
        var text = [CChar](repeating: 0, count: DesktopClipboardVoiceCommands.maximumClipboardUTF8Bytes + 1)
        var error = [CChar](repeating: 0, count: 1024)
        let status = jsti_windows_clipboard_read_run(handle, &text, text.count, &error, error.count)
        return try DesktopNativeClipboardRead.result(status: status, text: text, error: String(cString: error))
    }

    func cancel() { jsti_windows_clipboard_read_cancel(handle) }
}
