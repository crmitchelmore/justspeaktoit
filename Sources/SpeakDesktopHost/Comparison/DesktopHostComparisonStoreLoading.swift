import Foundation
import SpeakDesktop

struct DesktopComparisonStoreLoading {
    let id = UUID()
    let task: Task<DesktopComparisonStore, Error>
}

extension DesktopHostController {
    package func loadComparisonStore() async throws -> DesktopComparisonStore {
        guard !closed else { throw CancellationError() }
        if let comparisons { return comparisons }
        activeOperations += 1
        defer { finishOperation() }
        if comparisonInitialization == nil {
            let root = directory.appendingPathComponent("Comparisons")
            comparisonInitialization = DesktopComparisonStoreLoading(task: Task {
                try Task.checkCancellation()
                try Platform.preparePrivateDirectory(root)
                let store = try DesktopComparisonStore(directory: root)
                try await store.pruneOrphanSamples()
                return store
            })
        }
        guard let loading = comparisonInitialization else {
            throw DesktopHostError(message: "Comparison initialization is unavailable.")
        }
        do {
            let store = try await loading.task.value
            guard !closed else { throw CancellationError() }
            comparisons = store
            if comparisonInitialization?.id == loading.id { comparisonInitialization = nil }
            return store
        } catch {
            if comparisonInitialization?.id == loading.id { comparisonInitialization = nil }
            throw error
        }
    }
}
