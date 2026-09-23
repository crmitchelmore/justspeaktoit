import Foundation
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

/// One automatic output owned by the controller's single output slot.
enum WindowsOutputJob: Sendable {
    /// Insert into the field captured at the recording hotkey.
    case insertion(WindowsInsertionTarget, WindowsTextOutputOptions)
    /// Copy without a destination, including for recordings started with
    /// Record in this window, which have no captured field.
    case clipboard(WindowsClipboardOutput)

    /// Nonblocking. A native operation already committed completes and is
    /// reported; nothing starts afterwards.
    func cancel() {
        switch self {
        case .insertion(let target, _): target.cancel()
        case .clipboard(let clipboard): clipboard.cancel()
        }
    }

    /// Blocking native output; never on the UI thread or the controller.
    func perform(_ text: String) -> String {
        guard !Task.isCancelled else { return "Output cancelled. Saved to History." }
        switch self {
        case .clipboard(let clipboard):
            do {
                try clipboard.copy(text)
                return "Transcript copied to the clipboard and saved to History."
            } catch {
                return "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
            }
        case .insertion(let target, let options):
            do {
                return WindowsInsertionStatus.message(for: try target.insert(text, options: options))
            } catch let failure as WindowsTextOutputError {
                return WindowsInsertionStatus.message(for: failure)
            } catch {
                return "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
            }
        }
    }
}
