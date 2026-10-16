import Foundation
import SpeakCore

public struct DesktopComparisonCandidate: Hashable, Sendable {
    public let modelID: String
    public let displayName: String
    public let providerName: String

    public init(modelID: String, displayName: String, providerName: String) {
        self.modelID = modelID
        self.displayName = displayName
        self.providerName = providerName
    }

    package func entry() -> ModelComparisonEntry {
        ModelComparisonEntry(modelID: modelID, modelDisplayName: displayName, providerDisplayName: providerName)
    }
}

public enum DesktopComparisonRunner {
    public static func completing(
        _ pending: ModelComparisonRound, entries: [ModelComparisonEntry], sample: ModelComparisonSample
    ) throws -> ModelComparisonRound {
        guard pending.entries.map(\.modelID) == entries.map(\.modelID) else {
            throw DesktopComparisonError.message("The comparison candidate snapshot changed.")
        }
        let identified = zip(pending.entries, entries).map { original, result in
            ModelComparisonEntry(
                id: original.id, modelID: original.modelID, modelDisplayName: original.modelDisplayName,
                providerDisplayName: original.providerDisplayName, transcript: result.transcript,
                errorDescription: result.errorDescription, timeToFirstPartialMs: result.timeToFirstPartialMs,
                timeToFinalMs: result.timeToFinalMs, estimatedCostUSD: result.estimatedCostUSD
            )
        }
        return ModelComparisonRound(
            id: pending.id, createdAt: pending.createdAt, updatedAt: Date(), inputMode: pending.inputMode,
            sample: sample, language: pending.language, originPlatform: pending.originPlatform,
            entries: identified, blindOrder: pending.blindOrder
        )
    }

    public static func validate(_ candidates: [DesktopComparisonCandidate]) throws {
        guard (2...8).contains(candidates.count), Set(candidates.map(\.modelID)).count == candidates.count else {
            throw DesktopComparisonError.message("Select two to eight different models.")
        }
    }

    /// `audio` is an app-owned immutable snapshot, never the mutable user's import.
    public static func file(
        audio: URL, pending: ModelComparisonRound, candidates: [DesktopComparisonCandidate],
        timeout: Duration = .seconds(120),
        transcribe: @escaping @Sendable (URL, DesktopComparisonCandidate, String?) async throws -> TranscriptionResult
    ) async throws -> ModelComparisonRound {
        try validate(candidates)
        guard pending.isValid, pending.inputMode != .streaming,
              pending.entries.map(\.modelID) == candidates.map(\.modelID) else {
            throw DesktopComparisonError.message("Invalid file comparison snapshot.")
        }
        let entries = await withTaskGroup(of: (Int, ModelComparisonEntry).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    var entry = candidate.entry()
                    let started = ContinuousClock.now
                    do {
                        let result = try await DesktopComparisonDeadline.run(timeout: timeout) {
                            try await transcribe(audio, candidate, pending.language)
                        }
                        entry.transcript = result.text
                        if let cost = result.cost { entry.estimatedCostUSD = cost.totalCost }
                        if entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            entry.errorDescription = "The model returned no transcript."
                        }
                    } catch {
                        entry.errorDescription = error is CancellationError
                            ? "Comparison cancelled." : error.localizedDescription
                    }
                    entry.timeToFinalMs = milliseconds(started.duration(to: .now))
                    return (index, entry)
                }
            }
            var completed: [(Int, ModelComparisonEntry)] = []
            for await entry in group { completed.append(entry) }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return try completing(pending, entries: entries, sample: pending.sample)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
