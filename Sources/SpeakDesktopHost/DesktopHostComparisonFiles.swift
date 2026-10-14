import Foundation
import SpeakCore
import SpeakDesktop

struct ComparisonSampleSnapshot {
    let audio: URL
    let round: ModelComparisonRound
    let budget: DesktopComparisonImportBudget
}

extension DesktopHostController {
    func runComparisonFiles(_ paths: [String], configuration: DesktopComparisonConfiguration) async throws {
        guard !paths.isEmpty, let comparisons else {
            throw DesktopHostError(message: "Choose one or more audio samples.")
        }
        var prepared: [ComparisonSampleSnapshot] = []
        let mode: ModelComparisonInputMode = paths.count == 1 ? .file : .batch
        let plans = try await preflightComparisonSamples(paths, mode: mode, configuration: configuration)
        defer {
            comparisonStaging.releaseOwners(Set(plans.map(\.id)).subtracting(comparisonOwnedRoundIDs))
        }
        for plan in plans {
            try Task.checkCancellation()
            let snapshot = try await prepareComparisonSample(plan, mode: mode, configuration: configuration)
            do { try await comparisons.upsert(snapshot.round, isExecuting: true) } catch {
                discardComparisonImport(snapshot.audio)
                throw error
            }
            comparisonOwnedRoundIDs.insert(snapshot.round.id)
            prepared.append(snapshot)
        }
        try Task.checkCancellation()
        guard !closed, comparisonGeneration == configuration.generation, let first = prepared.first else {
            throw CancellationError()
        }
        if prepared.count > 1 {
            comparisonBatch = DesktopComparisonBatch(
                id: configuration.generation, configuration: configuration,
                currentRoundID: first.round.id, remaining: Array(prepared.dropFirst())
            )
        }
        try await runComparisonSample(first, configuration: configuration)
    }

    func runComparisonSample(
        _ snapshot: ComparisonSampleSnapshot, configuration: DesktopComparisonConfiguration
    ) async throws {
        try Task.checkCancellation()
        guard !closed, comparisonGeneration == configuration.generation, let comparisons else {
            throw CancellationError()
        }
        comparisonSelection = snapshot.round.id
        comparisonStatus("Comparing \(snapshot.round.sample.name)… Raw requests only.")
        await refreshComparison()
        try Task.checkCancellation()
        guard !closed, comparisonGeneration == configuration.generation else { throw CancellationError() }
        let staging = comparisonStaging
        let execution = DesktopComparisonFileExecution(
            operations: comparisonOperations,
            admitted: {
                try staging.retain(id: snapshot.round.id, operation: $0)
                try await comparisons.retainOperation(roundID: snapshot.round.id, operationID: $0)
            },
            exited: {
                await comparisons.releaseOperation(roundID: snapshot.round.id, operationID: $0)
                staging.release(id: snapshot.round.id, operation: $0)
                await self.comparisonOperationExited()
            },
            completed: { try snapshot.budget.record($0) }
        )
        let round = try await DesktopComparisonRunner.file(
            audio: snapshot.audio, pending: snapshot.round, candidates: configuration.selected,
            execution: execution
        ) { audio, candidate, language in
            guard let key = configuration.keys[candidate.modelID] else {
                throw DesktopHostError(message: "The comparison credential snapshot is missing.")
            }
            var request = DesktopHostTranscriptionRequest(
                audio: audio, model: candidate.modelID, key: key,
                duration: snapshot.round.sample.durationSeconds, language: language
            )
            request.modulateFeatures = configuration.modulateBatch
            return try await self.effects.transcribeComparison(
                request,
                azureEndpoint: configuration.endpoint, with: self
            )
        }
        try snapshot.budget.finish(round)
        try await comparisons.upsert(round)
        guard comparisonGeneration == configuration.generation else { return }
        comparisonSelection = round.id
        if comparisonBatch?.remaining.isEmpty == true { comparisonBatch = nil }
        comparisonStatus(
            comparisonBatch == nil ? "Comparison results saved. Review or rank the results below."
                : "Batch paused. Judge this round, then choose Next file. No further requests start automatically."
        )
        await refreshComparison()
    }

    private func comparisonOperationExited() {
        guard !closed else { return }
        comparisonSync?.changed()
    }

}
