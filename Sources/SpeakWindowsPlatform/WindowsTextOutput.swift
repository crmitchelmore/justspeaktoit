import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

/// Text output preferences for the Windows host. These mirror the macOS
/// product semantics (`TextOutputMethod` and `AccessibilityInsertionMode`)
/// rather than any Windows API: `smart` prefers direct insertion and falls
/// back to a guarded paste, `directOnly` never sends paste keys, and
/// `clipboardOnly` copies without inserting. An explicit app-switch policy
/// may use a recovery copy even when direct insertion is selected.
public struct WindowsTextOutputOptions: Codable, Equatable, Sendable, DesktopAppSwitchOutputOptions {
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
    /// Nil preserves the pre-policy captured-target behavior.
    public var appSwitchDelivery: AppSwitchDelivery?

    public init(method: Method = .smart, insertion: Insertion = .insertAtCursor, restoreClipboard: Bool = true) {
        self.method = method
        self.insertion = insertion
        self.restoreClipboard = restoreClipboard
        self.appSwitchDelivery = nil
    }

    private enum CodingKeys: String, CodingKey {
        case method, insertion, restoreClipboard, appSwitchDelivery
    }

    public init(appSwitchDelivery: AppSwitchDelivery?) {
        self.init()
        self.appSwitchDelivery = appSwitchDelivery
    }

    /// Legacy fields retain their defaults. A supplied destination policy is
    /// strict: invalid intent must not silently become unrelated insertion.
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
        appSwitchDelivery = try container.decodeIfPresent(AppSwitchDelivery.self, forKey: .appSwitchDelivery)
    }

    /// Native flag bits for `jsti_insertion_insert`.
    public var nativeFlags: UInt32 {
        var flags: UInt32 = 0
        if insertion == .replaceField { flags |= UInt32(JSTI_INSERTION_REPLACE_FIELD.rawValue) }
        if !restoreClipboard { flags |= UInt32(JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD.rawValue) }
        if method == .directOnly { flags |= UInt32(JSTI_INSERTION_NO_PASTE_FALLBACK.rawValue) }
        switch appSwitchDelivery {
        case .originalApp: flags |= UInt32(JSTI_INSERTION_ORIGINAL_APP.rawValue)
        case .currentApp: flags |= UInt32(JSTI_INSERTION_CURRENT_APP.rawValue)
        case .onlyIfOriginalAppInFront: flags |= UInt32(JSTI_INSERTION_ONLY_ORIGINAL_FRONT.rawValue)
        case nil: break
        }
        return flags
    }

    /// Stable integers for the native Text output dialog.
    public var nativeChoice: WindowsTextOutputNativeChoice {
        let method: JSTITextOutputMethod
        switch self.method {
        case .smart: method = JSTI_TEXT_OUTPUT_SMART
        case .directOnly: method = JSTI_TEXT_OUTPUT_DIRECT_ONLY
        case .clipboardOnly: method = JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY
        }
        let insertion = self.insertion == .replaceField ? JSTI_TEXT_OUTPUT_REPLACE_FIELD : JSTI_TEXT_OUTPUT_AT_CURSOR
        return WindowsTextOutputNativeChoice(
            method: Int32(method.rawValue), insertion: Int32(insertion.rawValue),
            restoreClipboard: restoreClipboard ? 1 : 0
        )
    }

    /// Nil outside the native contract, so a malformed Apply is never saved as
    /// a different choice.
    public init?(nativeChoice choice: WindowsTextOutputNativeChoice) {
        let method: Method
        switch choice.method {
        case Int32(JSTI_TEXT_OUTPUT_SMART.rawValue): method = .smart
        case Int32(JSTI_TEXT_OUTPUT_DIRECT_ONLY.rawValue): method = .directOnly
        case Int32(JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY.rawValue): method = .clipboardOnly
        default: return nil
        }
        let insertion: Insertion
        switch choice.insertion {
        case Int32(JSTI_TEXT_OUTPUT_AT_CURSOR.rawValue): insertion = .insertAtCursor
        case Int32(JSTI_TEXT_OUTPUT_REPLACE_FIELD.rawValue): insertion = .replaceField
        default: return nil
        }
        guard choice.restoreClipboard == 0 || choice.restoreClipboard == 1 else { return nil }
        self.init(method: method, insertion: insertion, restoreClipboard: choice.restoreClipboard == 1)
    }
}

/// The three values exchanged with `jsti_window_set_text_output` and its
/// Apply callback: method 0 smart, 1 direct only, 2 clipboard only; insertion
/// 0 at the cursor, 1 replace the field; restore 0 or 1.
public struct WindowsTextOutputNativeChoice: Equatable, Sendable {
    public let method: Int32
    public let insertion: Int32
    public let restoreClipboard: Int32

    public init(method: Int32, insertion: Int32, restoreClipboard: Int32) {
        self.method = method
        self.insertion = insertion
        self.restoreClipboard = restoreClipboard
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
        case clipboard
    }

    public enum ClipboardState: Equatable, Sendable {
        case untouched
        case restored
        case restoredPartially
        case transcriptLeft
        case restoreFailed
        case changedMeanwhile

        init(code: Int32) {
            switch code {
            case Int32(JSTI_INSERTION_CLIPBOARD_RESTORED.rawValue): self = .restored
            case Int32(JSTI_INSERTION_CLIPBOARD_RESTORED_PARTIALLY.rawValue): self = .restoredPartially
            case Int32(JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT.rawValue): self = .transcriptLeft
            case Int32(JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED.rawValue): self = .restoreFailed
            case Int32(JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE.rawValue): self = .changedMeanwhile
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

    let handle: OpaquePointer
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

    /// Capture the focused selection's identity before the settings queue hop.
    /// This native target also permits our own app, but cannot insert or copy.
    public static func captureSelection() throws -> WindowsInsertionTarget {
        var error = [CChar](repeating: 0, count: 1_024)
        guard let handle = jsti_selection_capture(&error, error.count) else {
            throw WindowsTextOutputError(String(cString: error))
        }
        return WindowsInsertionTarget(handle: handle)
    }

    /// Capture on the native UI callback. The bounded selection read retains an
    /// editable UIA range; insertion cannot redirect it or replace the whole field.
    public static func captureVoiceEdit() throws -> WindowsInsertionTarget {
        var error = [CChar](repeating: 0, count: 1_024)
        guard let handle = jsti_voice_edit_capture(&error, error.count) else {
            throw WindowsTextOutputError(String(cString: error))
        }
        return WindowsInsertionTarget(handle: handle)
    }

    public func selectedText() async throws -> String {
        let task = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            var text = [CChar](repeating: 0, count: 800_001)
            var error = [CChar](repeating: 0, count: 1_024)
            guard jsti_selection_read(self.handle, &text, text.count, &error, error.count) == 0 else {
                throw WindowsTextOutputError(String(cString: error))
            }
            return String(cString: text)
        }
        return try await withTaskCancellationHandler {
            let text = try await task.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            self.cancel()
            task.cancel()
        }
    }

    /// Requests abandonment without waiting for a blocked provider. Keep this
    /// object alive until the insertion call returns; its worker owns native state.
    public func cancel() { jsti_insertion_cancel(handle) }

    /// Full executable path from the process retained at capture. This performs
    /// no focus lookup or accessibility query, including after focus has moved.
    public var executablePath: String? {
        try? executablePathChecked()
    }

    public func executablePathChecked() throws -> String {
        var required = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = jsti_insertion_executable_path(handle, nil, 0, &required, &error, error.count)
        guard status == 2, required > 1, required <= 131_073 else {
            throw WindowsTextOutputError(String(cString: error))
        }
        var path = [CChar](repeating: 0, count: required)
        guard jsti_insertion_executable_path(
            handle, &path, path.count, &required, &error, error.count
        ) == 0 else { throw WindowsTextOutputError(String(cString: error)) }
        return String(cString: path)
    }

    public static func foregroundExecutablePath() throws -> String? {
        var path = [CChar](repeating: 0, count: 131_073)
        var error = [CChar](repeating: 0, count: 512)
        guard jsti_foreground_executable_path(&path, path.count, &error, error.count) == 0 else {
            throw WindowsTextOutputError(String(cString: error))
        }
        let value = String(cString: path)
        return value.isEmpty ? nil : value
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
        switch result.method {
        case Int32(JSTI_INSERTION_METHOD_NATIVE_EDIT.rawValue): method = .nativeEdit
        case Int32(JSTI_INSERTION_METHOD_UIA_VALUE.rawValue): method = .automationValue
        case Int32(JSTI_INSERTION_METHOD_PASTE.rawValue): method = .paste
        case Int32(JSTI_INSERTION_METHOD_CLIPBOARD.rawValue): method = .clipboard
        default:
            throw WindowsTextOutputError(
                "The native adapter reported success without an insertion method.", clipboard: clipboard,
                mayHaveInserted: true
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
    public static func delivery(for outcome: WindowsInsertionTarget.Outcome) -> DesktopTextOutputResult {
        if outcome.method == .clipboard {
            return DesktopTextOutputResult(
                .recoveryCopy, status: "Transcript copied; app-switch delivery did not insert text."
            )
        }
        return DesktopTextOutputResult(
            outcome.verified && (outcome.method == .nativeEdit || outcome.fieldIdentity)
                ? .confirmedInsertion : .unconfirmedInsertion,
            status: message(for: outcome)
        )
    }

    public static func message(for outcome: WindowsInsertionTarget.Outcome) -> String {
        var status: String
        switch outcome.method {
        case .nativeEdit, .automationValue:
            status = "Inserted into the original text field and saved to History."
            if !outcome.verified { status += " The field could not be read back to confirm the insertion." }
        case .paste:
            status = outcome.verified
                ? "Pasted into the original text field and saved to History."
                : "Paste keys sent; insertion could not be confirmed. Saved to History."
        case .clipboard:
            return "Transcript copied; app-switch delivery did not insert text."
        }
        if outcome.method != .nativeEdit, !outcome.fieldIdentity {
            status = "Insertion attempted; the original field could not be confirmed. Saved to History."
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
