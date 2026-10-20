import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
private actor OwnedStartupGate {
    private var opened: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var entries = 0
    private(set) var events: [String] = []
    private var reenter: (@Sendable () -> Void)?
    func onEntry(_ action: @escaping @Sendable () -> Void) { reenter = action }
    func record(_ value: String) {
        events.append(value)
        let action = reenter
        reenter = nil
        action?()
    }
    init(open: Bool = false) { opened = open }
    func pass() async {
        entries += 1
        observers.forEach { $0.resume() }; observers.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async {
        if entries == 0 { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
private actor OwnedStartupWorker: DesktopPressCaptureWorker {
    let opening: OwnedStartupGate
    let closing: OwnedStartupGate
    var failOpen = false
    var failClose = false
    private var failure: (@Sendable (String) -> Void)?
    private(set) var opens = 0
    private(set) var closes = 0
    init(opening: OwnedStartupGate = .init(open: true), closing: OwnedStartupGate = .init(open: true)) {
        self.opening = opening; self.closing = closing
    }
    func configure(open: Bool = false, close: Bool = false) { failOpen = open; failClose = close }
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        opens += 1
        failure = onFailure
        await opening.pass()
        if failOpen { throw DesktopHostError(message: "synthetic open") }
    }
    func close(id: UUID) async throws {
        closes += 1
        await closing.pass()
        if failClose { throw DesktopHostError(message: "synthetic close") }
    }
    func emitFailure() { failure?("synthetic capture") }
}
final class DesktopHostOwnedCaptureStartupTests: XCTestCase {
    private var directory: URL!
    private var host: DesktopHostController<FakePlatform>!
    private var effects: SyntheticEffects!
    private let identity = DesktopPressCaptureIdentity(
        deviceID: "synthetic-only", routeID: "synthetic/batch", profileID: "frozen",
        sampleRate: 16_000, frameMilliseconds: 100
    )
    private let admission = DesktopPressCaptureAdmission(
        enabled: true, capability: .qualified, permission: .granted, owner: .idle
    )
    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-host-\(UUID())")
        effects = SyntheticEffects()
        host = try DesktopHostController(directory: directory, effects: effects, shutdownGrace: .milliseconds(30))
        await host.markReadyForSelfTest()
    }
    override func tearDown() async throws {
        await host.close()
        try FileManager.default.removeItem(at: directory)
    }
    private func admit(_ dependency: DesktopHostOwnedStartupDependency) async throws -> DesktopHostOwnedStartup {
        try await host.admitOwnedCaptureStartup(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 160, reservedFrames: 320), dependency: dependency
        )
    }
    @discardableResult
    private func phase(
        _ owner: DesktopHostOwnedStartup, _ expected: DesktopHostOwnedStartupSnapshot.Phase,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> DesktopHostOwnedStartupSnapshot {
        for _ in 0..<1_500 {
            let snapshot = await owner.snapshot()
            if snapshot.phase == expected { return snapshot }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let snapshot = await owner.snapshot()
        XCTFail("Expected \(expected), got \(snapshot.phase)", file: file, line: line)
        return snapshot
    }
    func testDefaultUnavailableAndPreparedIsNotActiveRecording() async throws {
        do {
            _ = try await host.admitOwnedCaptureStartup(
                identity: identity, admission: admission,
                limits: DesktopPressCaptureBufferLimits(preRollFrames: 160, reservedFrames: 320)
            )
            XCTFail("A default factory must not exist")
        } catch {}
        try await host.saveConfiguration(DesktopConfiguration(values: [
            "handsFreeDictationEnabled": AnyCodable(.bool(true))
        ]).entries)
        let owner = try await admit(.init(worker: OwnedStartupWorker()))
        await phase(owner, .prepared)
        await host.toggle(
            target: nil, modelIndex: 0, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await host.shortcut(.init(
            input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
            target: nil, targetExecutablePath: nil, textOutput: Task { FakeTextOutput() }, modelIndex: 0, deviceID: ""
        ))
        await host.comparisonEvent(102, text: "synthetic", index: 0)
        let armed = await host.handsFreeMachine.isArmed
        XCTAssertFalse(armed)
        let recording = await host.recording
        let busy = await host.busy
        XCTAssertNil(recording); XCTAssertTrue(busy)
        await host.cancelTranscription()
        await owner.waitForDisposition()
        XCTAssertTrue(effects.outputs.isEmpty)
        XCTAssertTrue(FakeLog.shared.huds.allSatisfy { $0.phase == .hidden || $0.phase == .failure })
        XCTAssertFalse(FakeLog.shared.states.contains(1))
        let records = try await host.store.records()
        XCTAssertEqual(records.count, 1)
        let audio = try await host.store.audioURL(for: XCTUnwrap(records.first))
        XCTAssertEqual(try Data(contentsOf: audio).count, 44)
    }
    func testFailureBeforeRealTicketDeliveryRetainsCleanupAndExplicitRetry() async throws {
        let delivery = OwnedStartupGate()
        let finishing = OwnedStartupGate(open: true)
        let worker = OwnedStartupWorker()
        await worker.configure(open: true, close: true)
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.deliverTicket = { _ in await delivery.pass() }
        dependency.beforeFile = { if case .finish = $0 { await finishing.pass() } }
        let owner = try await admit(dependency)
        await delivery.entered()
        await worker.closing.entered()
        for _ in 0..<1_500 {
            if await owner.snapshot().causes.count == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let early = await owner.snapshot()
        XCTAssertEqual(early.phase, .preparing); XCTAssertEqual(early.causes.count, 2)
        XCTAssertNotNil(early.token)
        let finishesBeforeTicket = await finishing.entries
        XCTAssertEqual(finishesBeforeTicket, 0)
        await host.cancelTranscription()
        await delivery.release()
        let failed = await phase(owner, .cleanupFailed)
        XCTAssertNotNil(failed.cleanupFailure)
        await host.cancelTranscription()
        let closeCount = await worker.closes
        XCTAssertEqual(closeCount, 1)
        do { _ = try await admit(.init(worker: OwnedStartupWorker())); XCTFail("Exclusion lost") } catch {}
        await worker.configure()
        try await owner.retryRelease()
        await owner.waitForDisposition()
        let finished = await phase(owner, .finished)
        let finalCloses = await worker.closes
        let finishCount = await finishing.entries
        XCTAssertEqual(finished.attempt, 1); XCTAssertEqual(finalCloses, 2); XCTAssertEqual(finishCount, 1)
        let record = try await host.store.record(id: finished.recordID)
        XCTAssertTrue(record.failure?.contains("openFailed") == true)
    }
    func testCancelBeforeNativeAdmissionWhileFileCreationIsHeld() async throws {
        let create = OwnedStartupGate()
        let worker = OwnedStartupWorker()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { if case .create = $0 { await create.pass() } }
        let owner = try await admit(dependency)
        await create.entered()
        await owner.abort()
        await create.release()
        await owner.waitForDisposition()
        let opens = await worker.opens
        XCTAssertEqual(opens, 0)
        let busy = await host.busy
        XCTAssertFalse(busy)
    }
    func testShutdownBeyondGraceRetainsOpeningAndClosingThenPersistsWithoutUI() async throws {
        let opening = OwnedStartupGate()
        let closing = OwnedStartupGate()
        let finishing = OwnedStartupGate(open: true)
        let worker = OwnedStartupWorker(opening: opening, closing: closing)
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { if case .finish = $0 { await finishing.pass() } }
        let owner = try await admit(dependency)
        await opening.entered()
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved); XCTAssertEqual(report.unfinishedOperations, 1)
        let statuses = FakeLog.shared.allStatuses
        await opening.release()
        await closing.entered()
        let before = await finishing.entries
        XCTAssertEqual(before, 0)
        await closing.release()
        await owner.waitForDisposition()
        let final = await owner.snapshot()
        let record = try await host.store.record(id: final.recordID)
        XCTAssertNotNil(record.failure)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        let operations = await host.activeOperations
        XCTAssertEqual(operations, 0)
    }
    func testFailedCloseCanRetryAfterControllerClosed() async throws {
        let worker = OwnedStartupWorker()
        await worker.configure(close: true)
        let owner = try await admit(.init(worker: worker))
        await phase(owner, .prepared)
        await worker.opening.entered()
        await owner.abort()
        await phase(owner, .cleanupFailed)
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved)
        let statuses = FakeLog.shared.allStatuses
        await worker.configure()
        try await owner.retryRelease()
        await owner.waitForDisposition()
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }
}
extension DesktopHostOwnedCaptureStartupTests {
    func testRealQueueDrainsWhileNativeAndFileOperationsAreHeld() async throws {
        let saving = OwnedStartupGate()
        let worker = OwnedStartupWorker()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { if case .initialSave = $0 { await saving.pass() } }
        let queue = DesktopSettingsQueue()
        let captured = dependency
        let host = try XCTUnwrap(host)
        let identity = identity
        let admission = admission
        let owner = await queue.read {
            try? await host.admitOwnedCaptureStartup(
                identity: identity, admission: admission,
                limits: DesktopPressCaptureBufferLimits(preRollFrames: 160, reservedFrames: 320),
                dependency: captured
            )
        }.value
        let actual = try XCTUnwrap(owner)
        await saving.entered()
        await queue.submit { await host.cancelTranscription() }.value
        await queue.drain()
        await saving.release()
        await actual.waitForDisposition()
        let opens = await worker.opens
        XCTAssertEqual(opens, 0)
    }
    func testHistorySaveFailureRetainsDispositionAndDoesNotRefinishWAV() async throws {
        let saving = OwnedStartupGate()
        let finishing = OwnedStartupGate(open: true)
        var dependency = DesktopHostOwnedStartupDependency(worker: OwnedStartupWorker())
        dependency.beforeFile = {
            if case .finalSave = $0 { await saving.pass() }
            if case .finish = $0 { await finishing.pass() }
        }
        let owner = try await admit(dependency)
        let prepared = await phase(owner, .prepared)
        await owner.abort()
        await saving.entered()
        let metadata = directory.appendingPathComponent("History").appendingPathComponent("\(prepared.recordID).json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        await saving.release()
        let failed = await phase(owner, .dispositionFailed)
        XCTAssertNotNil(failed.historyFailure)
        let busy = await host.busy
        XCTAssertTrue(busy)
        try FileManager.default.removeItem(at: metadata)
        try await owner.retryDisposition()
        await owner.waitForDisposition()
        let finishes = await finishing.entries
        XCTAssertEqual(finishes, 1)
        let saved = try await host.store.record(id: prepared.recordID)
        XCTAssertEqual(saved.id, prepared.recordID)
    }
    func testDistinctInjectedAudioFailureAndRealHistoryFailureAreRetained() async throws {
        let saving = OwnedStartupGate()
        var dependency = DesktopHostOwnedStartupDependency(worker: OwnedStartupWorker())
        dependency.afterFinish = { throw DesktopHostError(message: "synthetic post-finish fault") }
        dependency.beforeFile = { if case .finalSave = $0 { await saving.pass() } }
        let owner = try await admit(dependency)
        let prepared = await phase(owner, .prepared)
        await owner.abort()
        await saving.entered()
        let metadata = directory.appendingPathComponent("History").appendingPathComponent("\(prepared.recordID).json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        await saving.release()
        let failed = await phase(owner, .dispositionFailed)
        XCTAssertNotNil(failed.audioFailure); XCTAssertNotNil(failed.historyFailure)
        try FileManager.default.removeItem(at: metadata)
        try await owner.retryDisposition()
        await owner.waitForDisposition()
        let record = try await host.store.record(id: prepared.recordID)
        XCTAssertTrue(record.failure?.contains("Audio finalization failed") == true)
    }
    func testCaptureFailureAndDelayedOldRunCannotAffectReplacement() async throws {
        let worker = OwnedStartupWorker()
        let old = try await admit(.init(worker: worker))
        await phase(old, .prepared)
        await worker.opening.entered()
        await worker.emitFailure()
        await old.waitForDisposition()
        let replacement = try await admit(.init(worker: OwnedStartupWorker()))
        await phase(replacement, .prepared)
        let before = FakeLog.shared.allStatuses
        await worker.emitFailure()
        await old.abort()
        let oldState = await old.snapshot()
        await host.ownedStartupChanged(oldState)
        let busy = await host.busy
        XCTAssertTrue(busy); XCTAssertEqual(FakeLog.shared.allStatuses, before)
        await replacement.abort()
        await replacement.waitForDisposition()
    }
    func testShutdownDuringInitialHistorySaveKeepsTheFileOwner() async throws {
        let saving = OwnedStartupGate()
        let worker = OwnedStartupWorker()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { if case .initialSave = $0 { await saving.pass() } }
        let owner = try await admit(dependency)
        await saving.entered()
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved)
        await saving.release()
        await owner.waitForDisposition()
        let opens = await worker.opens
        XCTAssertEqual(opens, 0)
    }
    func testCancelledWaiterAndRealQueueCannotReleaseHeldNativeIO() async throws {
        let opening = OwnedStartupGate()
        let closing = OwnedStartupGate()
        let worker = OwnedStartupWorker(opening: opening, closing: closing)
        let owner = try await admit(.init(worker: worker))
        await opening.entered()
        let waiter = Task { await owner.waitForDisposition() }
        waiter.cancel()
        let queue = DesktopSettingsQueue()
        let host = try XCTUnwrap(host)
        await queue.submit { await host.cancelTranscription() }.value
        await queue.drain()
        let busy = await host.busy
        XCTAssertTrue(busy)
        await opening.release()
        await closing.entered()
        await queue.drain()
        await closing.release()
        await waiter.value
        await phase(owner, .finished)
    }
    func testBoundedFIFOOverflowBarrierAndReentrantSubmission() async throws {
        typealias Failure = DesktopPressCaptureFailureEvent
        let owner = try await admit(.init(worker: OwnedStartupWorker()))
        let state = await phase(owner, .prepared)
        let event = DesktopPressCaptureFailureEvent(
            token: try XCTUnwrap(state.token), identity: identity, error: .openFailed("first")
        )
        let second = Failure(token: event.token, identity: identity, error: .captureFailed("second"))
        let third = Failure(token: event.token, identity: identity, error: .cleanupFailed("third"))
        let first = OwnedStartupGate()
        let trace = OwnedStartupGate()
        let inbox = DesktopEventDispatcher<DesktopHostOwnedStartupNotice>(
            coalescing: { DesktopHostOwnedStartupNotice.enqueue(&$0, $1) },
            perform: { notice in
                switch notice {
                case .failure(let event): await trace.record(String(describing: event.error)); await first.pass()
                case .overflow: await trace.record("overflow")
                case .barrier(let barrier): await trace.record("barrier"); await barrier.acknowledge()
                }
            }
        )
        await trace.onEntry { inbox.submit(.failure(second)) }
        inbox.submit(.failure(event))
        await first.entered()
        for _ in 0..<100 { inbox.submit(.failure(third)) }
        let barrier = DesktopHostOwnedStartupBarrier()
        inbox.submit(.barrier(barrier))
        await first.release()
        await barrier.value()
        let events = await trace.events
        let expected = [event.error, second.error, third.error, third.error].map { String(describing: $0) }
        XCTAssertEqual(events, expected + ["overflow", "barrier"])
        await owner.receive(.overflow)
        await owner.waitForDisposition()
        let finished = await owner.snapshot()
        let record = try await host.store.record(id: finished.recordID)
        XCTAssertTrue(record.failure?.contains("overflow") == true)
    }
}
