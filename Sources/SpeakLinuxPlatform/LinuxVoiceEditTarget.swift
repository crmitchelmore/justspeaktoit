import Foundation
import CLinuxSupport
import SpeakDesktop

/// One voice-edit selection lease. It reads the captured selection once, stays
/// armed through dictation and replaces only that same selection, at most once.
/// Selected-text access in Voice Output authorises it for this session.
public final class LinuxVoiceEditTarget: DesktopVoiceEditTarget, @unchecked Sendable {
    // Released only in deinit, so cancel never waits for a replacement in flight.
    private let handle: OpaquePointer

    private init(_ handle: OpaquePointer) { self.handle = handle }

    deinit { jsti_atspi_selection_release(handle) }

    /// Never probes focus: it takes only the field already admitted.
    public static func captureAdmitted() -> LinuxVoiceEditTarget? {
        jsti_atspi_voice_edit_capture().map { LinuxVoiceEditTarget($0) }
    }

    public static var availability: String {
        "Voice edit needs a selection in an external app. " + LinuxSelectedTextTarget.availability
    }

    public var isCurrent: Bool { jsti_atspi_voice_edit_is_current(handle) == 1 }

    public func selectedText() async throws -> String {
        try Task.checkCancellation()
        let text = try await Task.detached { try self.read() }.value
        try Task.checkCancellation()
        return text
    }

    public func replace(with text: String) async -> DesktopVoiceEditReplacement {
        await Task.detached(priority: .userInitiated) { self.replaceNow(text) }.value
    }

    public func copyToClipboard(_ text: String) throws { try LinuxClipboard.write(text) }

    /// Revokes the lease; a replacement in flight stops before its next call.
    public func cancel() { jsti_atspi_voice_edit_cancel(handle) }

    private func read() throws -> String {
        var bytes = [CChar](repeating: 0, count: 32769)
        guard jsti_atspi_selection_read(handle, &bytes, bytes.count) == 1 else {
            throw LinuxNativeError(message: "The selection could not be read safely. Access, focus, selection "
                + "or privacy state changed, or the field is unsupported. Nothing was recorded or edited.")
        }
        return String(cString: bytes)
    }

    private func replaceNow(_ text: String) -> DesktopVoiceEditReplacement {
        guard text.unicodeScalars.count <= 8192 else {
            return .refused("The rewrite is longer than the 8,192 characters a field edit allows.")
        }
        switch text.withCString({ jsti_atspi_voice_edit_replace(handle, $0) }) {
        case 1: return .replaced
        case 0: return .refused(DesktopVoiceEditDelivery.targetChanged)
        default: return .indeterminate("The app did not confirm the replacement.")
        }
    }
}
