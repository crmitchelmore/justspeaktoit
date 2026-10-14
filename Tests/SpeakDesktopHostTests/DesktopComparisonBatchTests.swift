import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopComparisonBatchTests: XCTestCase {
    func testPausesWithQueuedLeaseAndValidatesRankingBeforeExplicitProgress() async throws {
        let fixture = try BatchFixture(count: 3)
        defer { fixture.remove() }
        await fixture.start()
        let store = try await fixture.store()
        let first = try await fixture.current()
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        let revisions = await store.pendingRevisions()
        XCTAssertEqual(revisions.map(\.id), [first.id], "Queued samples must retain their sync execution leases.")
        var controls = await fixture.controller.comparisonBatchControls(round: first)
        XCTAssertEqual(controls.remaining, 2)
        XCTAssertFalse(controls.canNext)
        await fixture.controller.comparisonEvent(106, text: first.id.uuidString + "\n1,1", index: 0)
        await fixture.controller.comparisonEvent(128, text: first.id.uuidString, index: 0)
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        await fixture.judge(first)
        let judged = try await fixture.current()
        controls = await fixture.controller.comparisonBatchControls(round: judged)
        XCTAssertTrue(controls.canNext)
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        await fixture.next(first)
        let second = try await fixture.current()
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(fixture.effects.bytes.count, 4)
        await fixture.judge(second)
        await fixture.next(first)
        XCTAssertEqual(fixture.effects.bytes.count, 4, "A stale Next-file action cannot consume a queued sample.")
        await fixture.next(second)
        XCTAssertEqual(fixture.effects.bytes.count, 6)
        let batch = await fixture.controller.comparisonBatch
        XCTAssertNil(batch)
        await fixture.controller.close()
    }

    func testCancelEditorCloseAndShutdownNeverStartQueuedRequestsAndRelaunchOnlyRecovers() async throws {
        for event: Int32 in [105, 123, 0] {
            let fixture = try BatchFixture(count: 2)
            defer { fixture.remove() }
            await fixture.start()
            let first = try await fixture.current()
            if event == 0 {
                let report = await fixture.controller.close()
                XCTAssertTrue(report.isComplete)
            } else {
                await fixture.controller.enqueueComparisonEvent(event, text: "", index: 0)
                await fixture.controller.comparisonTask?.value
            }
            await fixture.controller.enqueueComparisonEvent(128, text: first.id.uuidString, index: 0)
            await fixture.controller.comparisonAdmissionTask?.value
            XCTAssertEqual(fixture.effects.bytes.count, 2)
            let batch = await fixture.controller.comparisonBatch
            XCTAssertNil(batch)
            await fixture.controller.close()
            let effects = ComparisonHostEffects(sourceToMutate: fixture.root.appendingPathComponent("unused"))
            let reopened = try DesktopHostController<FakePlatform>(directory: fixture.root, effects: effects)
            await reopened.openComparison()
            let persisted = await reopened.comparisons
            let store = try XCTUnwrap(persisted)
            let rounds = await store.rounds()
            XCTAssertEqual(rounds.count, 2)
            XCTAssertTrue(effects.bytes.isEmpty)
            for round in rounds {
                let audio = store.directory.appendingPathComponent("Samples")
                    .appendingPathComponent(round.id.uuidString + ".wav")
                XCTAssertEqual(try Data(contentsOf: audio), fixture.bytes)
            }
            await reopened.close()
        }
    }

    func testFailedRoundRevealsWithoutRankingButStillRequiresNextFile() async throws {
        let fixture = try BatchFixture(count: 2)
        defer { fixture.remove() }
        fixture.effects.failedModels = Set(fixture.models)
        await fixture.start()
        let first = try await fixture.current()
        XCTAssertTrue(first.entries.allSatisfy(\.didFail))
        let controls = await fixture.controller.comparisonBatchControls(round: first)
        XCTAssertTrue(controls.canNext)
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        await fixture.next(first)
        XCTAssertEqual(fixture.effects.bytes.count, 4)
        let rounds = await (try fixture.store()).rounds()
        XCTAssertTrue(rounds.allSatisfy { !$0.isJudged })
        XCTAssertTrue(ModelComparisonScoreboard.scores(for: rounds).allSatisfy { $0.wins == 0 && $0.meanRank == nil })
        await fixture.controller.close()
    }

    func testNativeNextAdmissionCanBeCancelledWhilePlaybackIsHeld() async throws {
        let fixture = try BatchFixture(count: 2)
        defer { fixture.remove() }
        await fixture.start()
        let first = try await fixture.current()
        await fixture.judge(first)
        let gate = Gate(open: false)
        let stopping = await fixture.controller.holdBatchPlayback(gate)
        let queue = DesktopSettingsQueue()
        queue.submit {
            await fixture.controller.enqueueComparisonEvent(128, text: first.id.uuidString, index: 0)
        }
        await stopping.pass()
        let cancelled = Gate(open: false)
        queue.submit {
            await fixture.controller.enqueueComparisonEvent(123, text: "", index: 0)
            cancelled.release()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !cancelled.isOpen, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(cancelled.isOpen)
        gate.release()
        await queue.drain()
        await fixture.controller.comparisonAdmissionTask?.value
        await fixture.controller.comparisonTask?.value
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        await fixture.controller.openComparison()
        await fixture.next(first)
        XCTAssertEqual(fixture.effects.bytes.count, 2, "Reopening cannot revive cancelled Next-file admission.")
        await fixture.controller.close()
    }

    func testDiscardingCurrentRoundCancelsQueueWithoutDeletingQueuedRecoveryAudio() async throws {
        let fixture = try BatchFixture(count: 2)
        defer { fixture.remove() }
        await fixture.start()
        let first = try await fixture.current()
        let store = try await fixture.store()
        let before = await store.rounds()
        let queued = try XCTUnwrap(before.first { $0.id != first.id })
        await fixture.controller.comparisonEvent(120, text: first.id.uuidString, index: 0)
        await fixture.controller.comparisonTask?.value
        let remaining = await store.rounds()
        XCTAssertEqual(remaining.map(\.id), [queued.id])
        let audio = store.directory.appendingPathComponent("Samples")
            .appendingPathComponent(queued.id.uuidString + ".wav")
        XCTAssertEqual(try Data(contentsOf: audio), fixture.bytes)
        let batch = await fixture.controller.comparisonBatch
        XCTAssertNil(batch)
        await fixture.next(first)
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        await fixture.controller.close()
    }

    func testCancellingHeldDiscardKeepsCurrentRoundAndReleasesQueuedLeases() async throws {
        let fixture = try BatchFixture(count: 2)
        defer { fixture.remove() }
        await fixture.start()
        let first = try await fixture.current()
        let gate = Gate(open: false)
        let stopping = await fixture.controller.holdBatchPlayback(gate)
        await fixture.controller.comparisonEvent(120, text: first.id.uuidString, index: 0)
        await stopping.pass()
        await fixture.controller.comparisonEvent(105, text: "", index: 0)
        gate.release()
        await fixture.controller.comparisonTask?.value
        let store = try await fixture.store()
        let rounds = await store.rounds()
        XCTAssertEqual(rounds.count, 2)
        let pending = await store.pendingRevisions()
        XCTAssertEqual(pending.count, 2, "Cancelled discard cannot leave a queued execution lease stranded.")
        XCTAssertEqual(fixture.effects.bytes.count, 2)
        await fixture.controller.close()
    }
}

private struct BatchFixture {
    let root: URL
    let bytes: Data
    let models: [String]
    let paths: [String]
    let effects: ComparisonHostEffects
    let controller: DesktopHostController<FakePlatform>

    init(count: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 4, count: 3200), sampleRate: 16000))
        self.root = root
        self.bytes = bytes
        paths = try (0..<count).map { index in
            let file = root.appendingPathComponent("sample-\(index).wav")
            try bytes.write(to: file)
            return file.path
        }
        models = DesktopHostModels.visible.filter { !DesktopHostModels.isLive($0.id) }.prefix(2).map(\.id)
        effects = ComparisonHostEffects(sourceToMutate: root.appendingPathComponent("unused"))
        controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
    }

    func start() async {
        await controller.comparisonEvent(102, text: "en_GB\n" + models.joined(separator: "\t")
                                        + "\n" + paths.joined(separator: "\n"), index: 0)
        await controller.comparisonTask?.value
    }

    func store() async throws -> DesktopComparisonStore {
        let persisted = await controller.comparisons
        return try XCTUnwrap(persisted)
    }

    func current() async throws -> ModelComparisonRound {
        let selected = await controller.comparisonSelection
        let rounds = await (try store()).rounds()
        return try XCTUnwrap(rounds.first { $0.id == selected })
    }

    func judge(_ round: ModelComparisonRound) async {
        await controller.comparisonEvent(106, text: round.id.uuidString + "\n1,2", index: 0)
    }

    func next(_ round: ModelComparisonRound) async {
        await controller.comparisonEvent(128, text: round.id.uuidString, index: 0)
        await controller.comparisonTask?.value
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension DesktopHostController where Platform == FakePlatform {
    func holdBatchPlayback(_ gate: Gate) -> Gate {
        playback.stopping.hold()
        playback.stopGate = gate
        return playback.stopping
    }
}
