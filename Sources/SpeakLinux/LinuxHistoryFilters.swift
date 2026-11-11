import SpeakDesktop
import SpeakDesktopNativeBindings

extension LinuxHostPlatform {
    package static func historyFilters(models: [String], selection: DesktopHistoryFilter) {
        if !DesktopNativeBindings.historyFilters(models: models, selection: selection) {
            update("Could not update History filter controls.")
        }
    }
}
