import Foundation
import SpeakDesktop

extension DesktopHostController {
    func comparisonMaintenanceEvent(_ event: Int32, text: String) {
        if event == 109 { playback.stop(announcing: true) } else { requestComparisonDeletion(text) }
    }

    func requestComparisonDeletion(_ identifier: String) {
        guard !closed, !busy, comparisonTask == nil, comparisonFinalization == nil,
              let id = UUID(uuidString: identifier), let comparisons else {
            comparisonStatus("Finish the current operation and select a saved comparison before deleting.")
            return
        }
        busy = true
        activeOperations += 1
        let generation = UUID()
        comparisonGeneration = generation
        comparisonTask = Task {
            do {
                try await self.playback.stopAndWait()
                try Task.checkCancellation()
                guard !self.closed, self.comparisonGeneration == generation else { throw CancellationError() }
                try await comparisons.remove(id: id)
                self.comparisonSync?.changed()
                if self.comparisonSelection == id { self.comparisonSelection = nil }
                self.comparisonStatus("Comparison deleted. Original imported files were not changed.")
            } catch {
                self.comparisonStatus("Comparison deletion: \(error.localizedDescription)")
            }
            self.comparisonTask = nil
            self.busy = false
            self.finishOperation()
            await self.refreshComparison()
        }
    }
}
