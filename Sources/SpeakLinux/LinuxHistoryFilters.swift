import Foundation
import CLinuxSupport
import SpeakDesktop

extension LinuxHostPlatform {
    package static func historyFilters(models: [String], selection: DesktopHistoryFilter) {
        let strings = DesktopNativeStrings()
        let rows = models.map { model in
            JSTIHistoryFilterModel(
                id: strings.add(model), name: strings.add(DesktopHistorySearch.modelDisplayName(for: model)),
                selected: selection.models.contains(model) ? 1 : 0
            )
        }
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer {
                jsti_window_set_history_filters(
                    $0.baseAddress, $0.count, selection.errorsOnly ? 1 : 0, selection.fromDay, selection.throughDay
                )
            }
        }
        if result != 0 { update("Could not update History filter controls.") }
    }
}
