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
    private static let defaultOperations = DesktopComparisonOperations()
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
        guard candidates.count >= 2, Set(candidates.map(\.modelID)).count == candidates.count else {
            throw DesktopComparisonError.message("Select at least two different models.")
        }
    }

    /// `audio` is an app-owned immutable snapshot, never the mutable user's import.
    public static func file(
        audio: URL, pending: ModelComparisonRound, candidates: [DesktopComparisonCandidate],
        timeout: Duration = .seconds(120),
        transcribe: @escaping @Sendable (URL, DesktopComparisonCandidate, String?) async throws -> TranscriptionResult
    ) async throws -> ModelComparisonRound {
        try await file(
            audio: audio, pending: pending, candidates: candidates, timeout: timeout,
            execution: .init(operations: defaultOperations, admitted: { _ in }, exited: { _ in }),
            transcribe: transcribe
        )
    }

    package static func file(
        audio: URL, pending: ModelComparisonRound, candidates: [DesktopComparisonCandidate],
        timeout: Duration = .seconds(120), execution: DesktopComparisonFileExecution,
        transcribe: @escaping @Sendable (URL, DesktopComparisonCandidate, String?) async throws -> TranscriptionResult
    ) async throws -> ModelComparisonRound {
        try validate(candidates)
        guard pending.isValid, pending.inputMode != .streaming,
              pending.entries.map(\.modelID) == candidates.map(\.modelID) else {
            throw DesktopComparisonError.message("Invalid file comparison snapshot.")
        }
        let request = DesktopComparisonFileRequest(
            audio: audio, language: pending.language, timeout: timeout, execution: execution, transcribe: transcribe
        )
        let entries = try await withThrowingTaskGroup(of: (Int, ModelComparisonEntry).self) { group in
            var next = 0
            while next < min(candidates.count, DesktopComparisonOperations.capacity) {
                let index = next
                group.addTask { (index, try await request.run(candidates[index])) }
                next += 1
            }
            var completed: [(Int, ModelComparisonEntry)] = []
            while let entry = try await group.next() {
                completed.append(entry)
                if next < candidates.count {
                    let index = next
                    group.addTask { (index, try await request.run(candidates[index])) }
                    next += 1
                }
            }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return try completing(pending, entries: entries, sample: pending.sample)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
