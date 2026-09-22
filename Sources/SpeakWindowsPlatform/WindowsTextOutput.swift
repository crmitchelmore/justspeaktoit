import Foundation
import CWindowsSupport

/// Text output preferences for the Windows host. These mirror the macOS
/// product semantics (`TextOutputMethod` and `AccessibilityInsertionMode`)
/// rather than any Windows API: `smart` prefers direct insertion and falls
/// back to a guarded paste, `directOnly` never touches the clipboard or
/// keyboard, and `clipboardOnly` copies without inserting.
public struct WindowsTextOutputOptions: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case smart
        case directOnly
        case clipboardOnly
    }

    public enum Insertion: String, Codable, Sendable {
        case insertAtCursor
        case replaceField
    }

    public var method: Method
    public var insertion: Insertion
    public var restoreClipboard: Bool

    public init(method: Method = .smart, insertion: Insertion = .insertAtCursor, restoreClipboard: Bool = true) {
        self.method = method
        self.insertion = insertion
        self.restoreClipboard = restoreClipboard
    }

    private enum CodingKeys: String, CodingKey {
        case method, insertion, restoreClipboard
    }

    /// Hand-edited settings may omit keys or carry unknown values; every field
    /// falls back to its default instead of failing the whole settings file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
            .flatMap(Method.init(rawValue:))
        let insertion = try container.decodeIfPresent(String.self, forKey: .insertion)
            .flatMap(Insertion.init(rawValue:))
        self.init(
            method: method ?? .smart,
            insertion: insertion ?? .insertAtCursor,
            restoreClipboard: try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        )
    }

    /// Native flag bits for `jsti_insertion_insert`.
    public var nativeFlags: UInt32 {
        var flags: UInt32 = 0
        if insertion == .replaceField { flags |= UInt32(JSTI_INSERTION_REPLACE_FIELD.rawValue) }
        if !restoreClipboard { flags |= UInt32(JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD.rawValue) }
        if method == .directOnly { flags |= UInt32(JSTI_INSERTION_NO_PASTE_FALLBACK.rawValue) }
        return flags
    }
}

public struct WindowsTextOutputError: LocalizedError, Equatable, Sendable {
    public let message: String
    public let clipboard: WindowsInsertionTarget.ClipboardState
    public let mayHaveInserted: Bool
    public var errorDescription: String? { message }

    public init(
        _ message: String, clipboard: WindowsInsertionTarget.ClipboardState = .untouched,
        mayHaveInserted: Bool = false
    ) {
        self.message = message
        self.clipboard = clipboard
        self.mayHaveInserted = mayHaveInserted
    }
}

/// Owns the opaque native insertion target captured at the recording hotkey.
/// Capture is synchronous and cheap; the native worker resolves the captured
/// focus event to its UI Automation element in the background. Insertion re-verifies
/// the original process, thread, window and focused control and never types
/// into another application. Destruction is nonblocking and happens exactly once,
/// on the last reference, so every recording outcome releases its worker.
public final class WindowsInsertionTarget: @unchecked Sendable {
    public enum Method: Equatable, Sendable {
        case nativeEdit
        case automationValue
        case paste
    }

    public enum ClipboardState: Equatable, Sendable {
        case untouched
        case restored
        case restoredPartially
        case transcriptLeft
        case restoreFailed
        case changedMeanwhile

        init(code: Int32) {
            switch UInt32(clamping: code) {
            case JSTI_INSERTION_CLIPBOARD_RESTORED.rawValue: self = .restored
            case JSTI_INSERTION_CLIPBOARD_RESTORED_PARTIALLY.rawValue: self = .restoredPartially
            case JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT.rawValue: self = .transcriptLeft
            case JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED.rawValue: self = .restoreFailed
            case JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE.rawValue: self = .changedMeanwhile
            default: self = .untouched
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let method: Method
        public let verified: Bool
        public let fieldIdentity: Bool
        public let clipboard: ClipboardState

        public init(method: Method, verified: Bool, fieldIdentity: Bool, clipboard: ClipboardState) {
            self.method = method
            self.verified = verified
            self.fieldIdentity = fieldIdentity
            self.clipboard = clipboard
        }
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    private var inserting = false

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit { jsti_insertion_destroy(handle) }

    /// Start focus-event observation before the user switches to a target app.
    public static func prepare() { jsti_insertion_prepare() }

    /// Call from the native UI callback before any actor hop, so the target is
    /// the field that had focus when the hotkey fired.
    public static func capture() throws -> WindowsInsertionTarget {
        var error = [CChar](repeating: 0, count: 1_024)
        guard let handle = jsti_insertion_capture(&error, error.count) else {
            throw WindowsTextOutputError(String(cString: error))
        }
        return WindowsInsertionTarget(handle: handle)
    }

    /// Requests abandonment without waiting for a blocked provider. Keep this
    /// object alive until the insertion call returns; its worker owns native state.
    public func cancel() { jsti_insertion_cancel(handle) }

    /// Full executable path from the process retained at capture. This performs
    /// no focus lookup or accessibility query, including after focus has moved.
    public var executablePath: String? {
        var required = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = jsti_insertion_executable_path(handle, nil, 0, &required, &error, error.count)
        guard status == 2, required > 1, required <= 131_073 else { return nil }
        var path = [CChar](repeating: 0, count: required)
        guard jsti_insertion_executable_path(
            handle, &path, path.count, &required, &error, error.count
        ) == 0 else { return nil }
        return String(cString: path)
    }

    /// Copies for an explicit clipboard-only output request. Native cancellation
    /// is checked after acquiring and snapshotting the clipboard, before writing.
    public func copy(_ text: String) throws {
        let claimed = lock.withLock { () -> Bool in
            guard !inserting else { return false }
            inserting = true
            return true
        }
        guard claimed else { throw WindowsTextOutputError("An output operation is already in progress.") }
        defer { lock.withLock { inserting = false } }
        var result = JSTIInsertionResult()
        var error = [CChar](repeating: 0, count: 1_024)
        let status = text.withCString { pointer in
            jsti_insertion_copy_text(handle, pointer, &result, &error, error.count)
        }
        guard status == 0 else {
            throw WindowsTextOutputError(String(cString: error), clipboard: ClipboardState(code: result.clipboard))
        }
    }

    /// Blocks for a bounded time (about six seconds worst case). One insertion
    /// at a time per target; a concurrent call fails instead of queueing.
    public func insert(_ text: String, options: WindowsTextOutputOptions = .init()) throws -> Outcome {
        let claimed = lock.withLock { () -> Bool in
            guard !inserting else { return false }
            inserting = true
            return true
        }
        guard claimed else { throw WindowsTextOutputError("An insertion is already in progress for this field.") }
        defer { lock.withLock { inserting = false } }
        var result = JSTIInsertionResult()
        var error = [CChar](repeating: 0, count: 1_024)
        let status = text.withCString { pointer in
            jsti_insertion_insert(handle, pointer, options.nativeFlags, &result, &error, error.count)
        }
        let clipboard = ClipboardState(code: result.clipboard)
        guard status == 0 else {
            throw WindowsTextOutputError(String(cString: error), clipboard: clipboard, mayHaveInserted: status == 1)
        }
        let method: Method
        switch UInt32(clamping: result.method) {
        case JSTI_INSERTION_METHOD_NATIVE_EDIT.rawValue: method = .nativeEdit
        case JSTI_INSERTION_METHOD_UIA_VALUE.rawValue: method = .automationValue
        case JSTI_INSERTION_METHOD_PASTE.rawValue: method = .paste
        default:
            throw WindowsTextOutputError(
                "The native adapter reported success without an insertion method.", clipboard: clipboard
            )
        }
        return Outcome(
            method: method, verified: result.verified != 0,
            fieldIdentity: UInt32(clamping: result.identity) == JSTI_INSERTION_IDENTITY_FIELD.rawValue,
            clipboard: clipboard
        )
    }
}

/// User-facing status text for insertion outcomes. Never includes transcript
/// or clipboard contents.
public enum WindowsInsertionStatus {
    public static func message(for outcome: WindowsInsertionTarget.Outcome) -> String {
        var status: String
        switch outcome.method {
        case .nativeEdit, .automationValue:
            status = "Inserted into the original text field and saved to History."
            if !outcome.verified { status += " The field could not be read back to confirm the insertion." }
        case .paste:
            status = outcome.verified
                ? "Pasted into the original text field and saved to History."
                : "Pasted into the original text field; the result could not be confirmed. Saved to History."
        }
        if let note = clipboardNote(for: outcome.clipboard) { status += " " + note }
        return status
    }

    public static func message(for failure: WindowsTextOutputError) -> String {
        let prefix = failure.mayHaveInserted
            ? "Saved. Insertion could not be confirmed. Check the original field before trying again."
            : "Saved. Automatic insertion unavailable; select Copy."
        var status = "\(prefix) \(failure.message)"
        switch failure.clipboard {
        case .transcriptLeft, .restoreFailed, .changedMeanwhile, .restoredPartially:
            if let note = clipboardNote(for: failure.clipboard) { status += " " + note }
        case .untouched, .restored:
            break
        }
        return status
    }

    static func clipboardNote(for state: WindowsInsertionTarget.ClipboardState) -> String? {
        switch state {
        case .untouched: return nil
        case .restored: return "Your previous clipboard content was restored."
        case .restoredPartially:
            return "Your previous clipboard text was restored; some formats could not be preserved."
        case .transcriptLeft: return "The transcript remains on the clipboard."
        case .restoreFailed: return "Your previous clipboard content could not be restored."
        case .changedMeanwhile: return "The clipboard changed meanwhile and was left as is."
        }
    }
}
