import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopComparisonOperationsTests: XCTestCase {
    func testManyFileModelsUseSlidingWorkersAndKeepExactSnapshotOrderAndBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("synthetic.wav")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: audio)
        let candidates = (0..<65).map {
            DesktopComparisonCandidate(modelID: "synthetic-\($0)", displayName: "\($0)", providerName: "Test")
        }
        let entries = candidates.map { $0.entry() }
        let pending = ModelComparisonRound(
            inputMode: .file, sample: .init(name: "Synthetic", contentHash: nil, durationSeconds: 1),
            language: "en_GB", originPlatform: "test", entries: entries, blindOrder: entries.reversed().map(\.id)
        )
        let observations = ComparisonOperationCounts()
        let round = try await DesktopComparisonRunner.file(
            audio: audio, pending: pending, candidates: candidates,
            execution: .init(operations: .init(), admitted: { _ in }, exited: { _ in })
        ) { file, candidate, language in
            observations.enter()
            defer { observations.exit() }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(language, "en_GB")
            try await Task.sleep(for: .milliseconds(5))
            return TranscriptionResult(
                text: candidate.modelID, segments: [], confidence: nil, duration: 1,
                modelIdentifier: candidate.modelID, cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        XCTAssertEqual(observations.started, 65)
        XCTAssertLessThanOrEqual(observations.maximum, 8)
        XCTAssertEqual(round.entries.map(\.modelID), candidates.map(\.modelID))
        XCTAssertEqual(round.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(round.blindOrder, pending.blindOrder)
        XCTAssertTrue(round.entries.allSatisfy { !$0.didFail && $0.timeToFinalMs != nil })
    }

    func testRepeatedDeadlinesKeepEightUnderlyingOperationsWithoutReplacementAdmission() async throws {
        let pool = DesktopComparisonOperations()
        let hold = ComparisonOperationHold()
        for _ in 0..<DesktopComparisonOperations.capacity {
            do {
                _ = try await pool.run(timeout: .milliseconds(30), admitted: { _ in }, exited: { _ in }, operation: {
                    await hold.wait()
                    return 1
                })
                XCTFail("Expected deadline")
            } catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        }
        XCTAssertEqual(pool.activeCount, 8)
        pool.cancelAll()
        for _ in 0..<3 {
            do {
                _ = try await pool.run(timeout: .seconds(1), admitted: { _ in }, exited: { _ in }, operation: { 2 })
                XCTFail("A logical timeout or cancellation must not free an underlying operation slot")
            } catch { XCTAssertTrue(error.localizedDescription.contains("still owned")) }
        }
        XCTAssertEqual(pool.activeCount, 8)
        try await assertFileBudgetUnavailable(pool)
        hold.release()
        await waitForExit(pool)
        XCTAssertEqual(pool.activeCount, 0)
        let value = try await pool.run(timeout: .seconds(1), admitted: { _ in }, exited: { _ in }, operation: { 3 })
        XCTAssertEqual(value, 3)
    }

    func testCancellationReturnsWithoutJoiningAndKeepsAudioLeaseUntilActualExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopComparisonStore(directory: root)
        let round = operationRound()
        try await store.upsert(round, isExecuting: true)
        let samples = root.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let audio = samples.appendingPathComponent(round.id.uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        let pool = DesktopComparisonOperations()
        let entered = ComparisonOperationHold()
        let hold = ComparisonOperationHold()
        let staging = DesktopComparisonStaging(limit: 3)
        try staging.reserve(id: round.id, bytes: 3)
        let task = Task {
            try await pool.run(
                timeout: .seconds(30),
                admitted: {
                    try staging.retain(id: round.id, operation: $0)
                    try await store.retainOperation(roundID: round.id, operationID: $0)
                },
                exited: {
                    await store.releaseOperation(roundID: round.id, operationID: $0)
                    staging.release(id: round.id, operation: $0)
                },
                operation: {
                    entered.release()
                    await hold.wait()
                    return try Data(contentsOf: audio)
                }
            )
        }
        await entered.wait()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch {
            XCTFail("Unexpected failure: \(error)")
        }
        await store.endExecution(ids: [round.id])
        staging.releaseOwners([round.id])
        XCTAssertEqual(staging.byteCount, 3)
        try await assertAudioInUse(round, store: store, audio: audio)
        XCTAssertEqual(pool.activeCount, 1)
        hold.release()
        await waitForExit(pool)
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertEqual(staging.byteCount, 0)
        try await store.remove(id: round.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testCancelDuringLeaseAdmissionNeverStartsProviderAndReleasesReservation() async throws {
        let pool = DesktopComparisonOperations()
        let entered = ComparisonOperationHold()
        let admission = ComparisonOperationHold()
        let task = Task {
            try await pool.run(timeout: .seconds(1), admitted: { _ in
                entered.release()
                await admission.wait()
            }, exited: { _ in }, operation: {
                XCTFail("Cancelled admission cannot start a provider")
                return 1
            })
        }
        await entered.wait()
        pool.cancelAll()
        task.cancel()
        admission.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        await waitForExit(pool)
        XCTAssertEqual(pool.activeCount, 0)
    }

    private func assertAudioInUse(
        _ round: ModelComparisonRound, store: DesktopComparisonStore, audio: URL
    ) async throws {
        try await store.upsert(round)
        do { try await store.remove(id: round.id); XCTFail("Audio is still in use") } catch {}
        do {
            try await store.applyRemoteRevision(ModelComparisonRevision(deleting: round.id, at: Date()))
            XCTFail("Sync must not delete owned audio")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
        let pending = await store.pendingRevisions()
        XCTAssertTrue(pending.isEmpty)
    }

    private func assertFileBudgetUnavailable(_ pool: DesktopComparisonOperations) async throws {
        let candidates = ["first", "second"].map {
            DesktopComparisonCandidate(modelID: $0, displayName: $0, providerName: "Synthetic")
        }
        let entries = candidates.map { $0.entry() }
        let pending = ModelComparisonRound(
            inputMode: .file, sample: .init(name: "Unadmitted", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "test", entries: entries, blindOrder: entries.map(\.id)
        )
        let round = try await DesktopComparisonRunner.file(
            audio: FileManager.default.temporaryDirectory.appendingPathComponent("unadmitted.wav"),
            pending: pending, candidates: candidates,
            execution: .init(operations: pool, admitted: { _ in }, exited: { _ in })
        ) { _, _, _ in
            XCTFail("A new File/Next attempt cannot replace timed-out underlying work")
            throw CancellationError()
        }
        XCTAssertTrue(round.entries.allSatisfy {
            $0.didFail && $0.timeToFinalMs == nil && $0.errorDescription?.contains("still owned") == true
        })
        XCTAssertEqual(pool.activeCount, 8)
    }

    private func waitForExit(_ pool: DesktopComparisonOperations) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pool.activeCount > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func operationRound() -> ModelComparisonRound {
        let entry = ModelComparisonEntry(modelID: "test", modelDisplayName: "Test", providerDisplayName: "Synthetic")
        return ModelComparisonRound(
            inputMode: .file, sample: .init(name: "Synthetic", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "test", entries: [entry], blindOrder: [entry.id]
        )
    }
}

private final class ComparisonOperationHold: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if open { return true }
                waiters.append(continuation)
                return false
            }

            if ready { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            open = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private final class ComparisonOperationCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var count = 0
    var started: Int { lock.withLock { count } }
    var maximum: Int { lock.withLock { peak } }
    func enter() { lock.withLock { active += 1; count += 1; peak = max(peak, active) } }
    func exit() { lock.withLock { active -= 1 } }
}
