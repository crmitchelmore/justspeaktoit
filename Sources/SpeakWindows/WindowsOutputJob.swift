import Foundation
import SpeakDesktop
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
        performResult(text).status
    }

    func performResult(_ text: String) -> DesktopTextOutputResult {
        guard !Task.isCancelled else {
            return DesktopTextOutputResult(.cancelled, status: "Output cancelled. Saved to History.")
        }
        switch self {
        case .clipboard(let clipboard):
            do {
                try clipboard.copy(text)
                return DesktopTextOutputResult(
                    .copied, status: "Transcript copied to the clipboard and saved to History."
                )
            } catch {
                return DesktopTextOutputResult(
                    .failed,
                    status: "Saved. The transcript could not be copied; select Copy. \(error.localizedDescription)"
                )
            }
        case .insertion(let target, let options):
            do {
                let outcome = try target.insert(text, options: options)
                if outcome.method == .clipboard {
                    return DesktopTextOutputResult(
                        .recoveryCopy,
                        status: "Transcript copied. The app-switch destination was unavailable or changed; "
                            + "nothing was inserted."
                    )
                }
                let result = WindowsInsertionStatus.delivery(for: outcome)
                guard options.appSwitchDelivery == .currentApp else { return result }
                return DesktopTextOutputResult(
                    result.disposition,
                    status: result.status.replacingOccurrences(
                        of: "original text field", with: "delivery-time text field"
                    )
                )
            } catch let failure as WindowsTextOutputError {
                let message = WindowsInsertionStatus.message(for: failure)
                return DesktopTextOutputResult(
                    failure.mayHaveInserted ? .unconfirmedInsertion : .failed,
                    status: options.appSwitchDelivery == .currentApp
                        ? message.replacingOccurrences(of: "original field", with: "delivery-time field") : message
                )
            } catch {
                return DesktopTextOutputResult(
                    .failed,
                    status: "Saved. Automatic insertion unavailable; select Copy. \(error.localizedDescription)"
                )
            }
        }
    }
}
