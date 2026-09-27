import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost

/// Window presentation beyond recording and History: the saved theme, and the
/// screenshot tour (`--ui-screenshots <folder>`), which opens a throwaway
/// window over the shared sample History and saves every page.
enum WindowsPresentation {
    /// The folder after `--ui-screenshots`, when the tour was asked for.
    static func screenshotDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--ui-screenshots"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func configureAppearance(_ controller: WindowsAppController) async {
        _ = jsti_window_set_appearance(Int32(await controller.appearance().rawValue))
    }

    /// General › Theme: the window already shows the choice; this keeps it.
    static func appearanceEvent(_ value: String, holder: WindowsEventContext) {
        guard let raw = Int(value), let appearance = DesktopAppearance(rawValue: raw) else { return }
        let controller = holder.controller
        holder.enqueueSettings { await controller.saveAppearance(appearance) }
    }

    /// Loads the sample History, then saves every page. False when no tour was asked for.
    static func startScreenshotTour(_ holder: WindowsEventContext) -> Bool {
        guard let directory = holder.screenshotDirectory else { return false }
        let controller = holder.controller
        Task {
            await controller.ready()
            do {
                try directory.withCString { path in
                    try WindowsNative.checked { jsti_window_screenshot_tour(path, $0, $1) }
                }
            } catch {
                holder.smokeTestFailure = error
                jsti_window_request_close()
            }
        }
        return true
    }
}
