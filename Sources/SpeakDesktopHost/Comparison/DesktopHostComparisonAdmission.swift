import Foundation

extension DesktopHostController {
    package func enqueueComparisonEvent(_ event: Int32, text: String, index: Int32) async {
        guard event == 102 || event == 103 || event == 128 else {
            await comparisonEvent(event, text: text, index: index)
            return
        }
        guard !closed else { return }
        guard comparisonAdmissionTask == nil else {
            comparisonStatus("Finish or cancel the current comparison admission first.")
            await refreshComparison()
            return
        }
        comparisonAdmissionTask = Task {
            await self.comparisonEvent(event, text: text, index: index)
            self.comparisonAdmissionTask = nil
        }
    }
}
