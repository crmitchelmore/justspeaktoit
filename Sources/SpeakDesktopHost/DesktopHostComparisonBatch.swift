import Foundation
import SpeakCore

struct DesktopComparisonBatch {
    let id: UUID
    let configuration: DesktopComparisonConfiguration
    var currentRoundID: UUID
    var remaining: [ComparisonSampleSnapshot]

    var queuedIDs: Set<UUID> { Set(remaining.map(\.round.id)) }
}

package struct DesktopComparisonBatchControls: Sendable {
    package var roundID = ""
    package var remaining = 0
    package var canNext = false
}

extension DesktopHostController {
    func nextComparisonFile(_ identifier: String) async {
        guard !closed, !Task.isCancelled, !busy, recording == nil, comparisonTask == nil,
              let batch = comparisonBatch, batch.currentRoundID.uuidString == identifier, let comparisons else {
            comparisonStatus("Select the paused batch round and finish or cancel the current operation first.")
            return
        }
        let generation = UUID()
        comparisonGeneration = generation
        busy = true
        activeOperations += 1
        var transferred = false
        defer {
            if !transferred {
                if comparisonGeneration == generation { comparisonGeneration = UUID() }
                busy = false
                finishOperation()
            }
        }
        do {
            let rounds = await comparisons.rounds()
            guard let round = rounds.first(where: { $0.id == batch.currentRoundID }),
                  round.isJudged || round.entries.filter({ !$0.didFail }).count < 2 else {
                throw DesktopHostError(message: "Save a complete blind ranking before choosing Next file.")
            }
            try await playback.stopAndWait()
            try Task.checkCancellation()
            guard !closed, comparisonVisible, comparisonGeneration == generation,
                  comparisonBatch?.id == batch.id, let sample = batch.remaining.first else { return }
            comparisonBatch?.remaining.removeFirst()
            comparisonBatch?.currentRoundID = sample.round.id
            let configuration = batch.configuration.reidentified(generation)
            launchComparison(configuration, live: false, paths: [], sample: sample)
            transferred = true
        } catch {
            comparisonStatus("Next file did not start: \(error.localizedDescription)")
        }
    }

    func comparisonBatchControls(round: ModelComparisonRound?) -> DesktopComparisonBatchControls {
        guard let batch = comparisonBatch else { return .init() }
        let revealed = round.map { $0.isJudged || $0.entries.filter { !$0.didFail }.count < 2 } ?? false
        return .init(
            roundID: batch.currentRoundID.uuidString, remaining: batch.remaining.count,
            canNext: !busy && recording == nil && comparisonTask == nil
                && round?.id == batch.currentRoundID && revealed && !batch.remaining.isEmpty
        )
    }

    func comparisonBatchNotice(queued: Bool) -> String {
        guard let batch = comparisonBatch else { return "" }
        return "\(batch.remaining.count) sample(s) queued. Next file is explicit; closing cancels the queue.\n"
            + (queued ? "This queued sample has not started any provider request.\n" : "")
    }

    func releaseComparisonFileExecution() async {
        let released = comparisonOwnedRoundIDs.subtracting(comparisonBatch?.queuedIDs ?? [])
        await comparisons?.endExecution(ids: released)
        comparisonOwnedRoundIDs.subtract(released)
        if comparisonBatch == nil, !comparisonOwnedRoundIDs.isEmpty {
            await comparisons?.endExecution(ids: comparisonOwnedRoundIDs)
            comparisonOwnedRoundIDs.removeAll()
        }
        comparisonSync?.changed()
    }

    func discardComparisonBatch() {
        guard comparisonBatch != nil else { return }
        comparisonBatch = nil
        if !closed { comparisonStatus("Batch queue cancelled. Saved audio and results remain as recovery evidence.") }
        guard comparisonTask == nil, !comparisonOwnedRoundIDs.isEmpty else { return }
        busy = true
        activeOperations += 1
        comparisonTask = Task {
            await self.releaseComparisonFileExecution()
            self.comparisonTask = nil
            self.busy = false
            self.finishOperation()
            await self.refreshComparison()
        }
    }
}

private extension DesktopComparisonConfiguration {
    func reidentified(_ generation: UUID) -> Self {
        Self(
            selected: selected, keys: keys, language: language, endpoint: endpoint,
            deviceID: deviceID, generation: generation
        )
    }
}
