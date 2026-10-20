import Foundation
import SpeakCore

package struct DesktopComparisonFileExecution: Sendable {
    let operations: DesktopComparisonOperations
    let admitted: @Sendable (UUID) async throws -> Void
    let exited: @Sendable (UUID) async -> Void
    let completed: @Sendable (ModelComparisonEntry) async throws -> Void

    package init(
        operations: DesktopComparisonOperations,
        admitted: @escaping @Sendable (UUID) async throws -> Void,
        exited: @escaping @Sendable (UUID) async -> Void,
        completed: @escaping @Sendable (ModelComparisonEntry) async throws -> Void = { _ in }
    ) {
        self.operations = operations
        self.admitted = admitted
        self.exited = exited
        self.completed = completed
    }
}

struct DesktopComparisonFileRequest: Sendable {
    let audio: URL
    let language: String?
    let timeout: Duration
    let execution: DesktopComparisonFileExecution
    let transcribe: @Sendable (URL, DesktopComparisonCandidate, String?) async throws -> TranscriptionResult

    func run(_ candidate: DesktopComparisonCandidate) async throws -> ModelComparisonEntry {
        var entry = candidate.entry()
        let timing = Timing()
        do {
            let result = try await execution.operations.run(
                timeout: timeout, admitted: execution.admitted, exited: execution.exited
            ) {
                timing.begin()
                return try await transcribe(audio, candidate, language)
            }
            entry.transcript = result.text
            if let cost = result.cost { entry.estimatedCostUSD = cost.totalCost }
            if entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.errorDescription = "The model returned no transcript."
            }
        } catch {
            entry.errorDescription = error is CancellationError ? "Comparison cancelled." : error.localizedDescription
        }
        entry.timeToFinalMs = timing.elapsed
        try await execution.completed(entry)
        return entry
    }

    private final class Timing: @unchecked Sendable {
        private let lock = NSLock()
        private var start: ContinuousClock.Instant?
        func begin() { lock.withLock { start = .now } }
        var elapsed: Int? {
            lock.withLock { start.map { DesktopComparisonRunner.milliseconds($0.duration(to: .now)) } }
        }
    }
}
