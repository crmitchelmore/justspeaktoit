import ApplicationServices
import Foundation

/// Revalidates a redirected destination at each write, including fallback.
enum AccessibilityInsertionWriter {
    static func insertAtCursor(
        text: String,
        selectedRange: () -> CFRange?,
        destinationError: () -> TextOutputError?,
        setSelectedText: () -> AXError,
        setValue: () -> AXError
    ) -> TextOutputResult {
        let selection = selectedRange()
        if let error = destinationError() { return TextOutputResult(method: .none, error: error) }
        guard setSelectedText() == .success else {
            return replaceAll(text: text, destinationError: destinationError, setValue: setValue)
        }
        return TextOutputResult(
            method: .accessibility, error: nil,
            insertedRange: selection.map { VoiceEditTextRange(location: $0.location, length: text.utf16.count) }
        )
    }

    static func replaceAll(
        text: String, destinationError: () -> TextOutputError?, setValue: () -> AXError
    ) -> TextOutputResult {
        if let error = destinationError() { return TextOutputResult(method: .none, error: error) }
        let status = setValue()
        guard status == .success else {
            return TextOutputResult(method: .none, error: TextOutputError.unableToSetValue(status))
        }
        return TextOutputResult(
            method: .accessibility, error: nil,
            insertedRange: VoiceEditTextRange(location: 0, length: text.utf16.count)
        )
    }
}
