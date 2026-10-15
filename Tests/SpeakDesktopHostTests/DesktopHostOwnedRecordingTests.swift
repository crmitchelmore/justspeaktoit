import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

private actor RecordingGate {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entries = 0
    init(open: Bool = false) { self.open = open }
    func pass() async {
        entries += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

// `RecordingWriteGate` lives in `DesktopHostRecordingWriteGateTests.swift`
// (same test target, `internal` visibility) alongside its own dedicated
// regression tests for the gate's blocking/release/timeout/concurrency
// behaviour; this file only consumes it below, unchanged from its original
// scenario and assertions otherwise.

private actor RecordingWorker: DesktopPressCaptureWorker {
    let opening: RecordingGate
    let closing: RecordingGate
    private var receive: (@Sendable (Data) -> Void)?
    private var failure: (@Sendable (String) -> Void)?
    private(set) var opens = 0
    private(set) var closes = 0
    var failClose = false
    init(opening: RecordingGate = .init(open: true), closing: RecordingGate = .init(open: true)) {
        self.opening = opening; self.closing = closing
    }
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        opens += 1; self.receive = receive; failure = onFailure
        await opening.pass()
    }
    func close(id: UUID) async throws {
        closes += 1
        await closing.pass()
        if failClose { throw DesktopHostError(message: "synthetic owned close") }
    }
    func configureFailure(_ value: Bool) { failClose = value }
    func emit(_ data: Data) { receive?(data) }
    func fail() { failure?("synthetic owned capture") }
}

final class DesktopHostOwnedRecordingTests: XCTestCase {
    private var directory: URL!
    private var host: DesktopHostController<FakePlatform>!
    private var effects: SyntheticEffects!
    private let identity = DesktopPressCaptureIdentity(
        deviceID: "synthetic", routeID: "synthetic/batch", profileID: "frozen",
        sampleRate: 16_000, frameMilliseconds: 100
    )
    private let admission = DesktopPressCaptureAdmission(
        enabled: true, capability: .qualified, permission: .granted, owner: .idle
    )
    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-\(UUID())")
        effects = SyntheticEffects()
        host = try DesktopHostController(directory: directory, effects: effects, shutdownGrace: .milliseconds(30))
        await host.markReadyForSelfTest()
    }
    override func tearDown() async throws {
        await host.close()
        try FileManager.default.removeItem(at: directory)
    }
    private func phase(
        _ owner: DesktopHostOwnedStartup, _ expected: DesktopHostOwnedStartupSnapshot.Phase
    ) async throws -> DesktopHostOwnedStartupSnapshot {
        for _ in 0..<1_500 {
            let snapshot = await owner.snapshot()
            if snapshot.phase == expected { return snapshot }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Did not reach \(expected)")
        return await owner.snapshot()
    }
    private func admit(_ dependency: DesktopHostOwnedStartupDependency) async throws -> DesktopHostOwnedStartup {
        let owner = try await host.admitOwnedCaptureStartup(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 3_200, reservedFrames: 6_400),
            dependency: dependency
        )
        _ = try await phase(owner, .prepared)
        return owner
    }
    private func promote(_ owner: DesktopHostOwnedStartup) async throws {
        try await host.requestOwnedRecording(requestID: owner.id)
        _ = try await phase(owner, .recording)
    }
    private func stop(_ owner: DesktopHostOwnedStartup) async throws -> DesktopRecordingStore.Record {
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        let outcome = await owner.waitForRecordingOutcome()
        return try await host.store.record(id: outcome.recordID)
    }
    private func payload(_ record: DesktopRecordingStore.Record) async throws -> Data {
        let url = try await host.store.audioURL(for: record)
        return Data(try Data(contentsOf: url).dropFirst(44))
    }
    private func pcm(_ bytes: Int) -> Data { Data((0..<bytes).map { UInt8($0 % 251) }) }

    func testHeldReadinessThenSingleOpenRealWAVAndCaptureOnlyHistory() async throws {
        let opening = RecordingGate()
        let worker = RecordingWorker(opening: opening)
        let owner = try await admit(.init(worker: worker))
        let prefix = pcm(4_000)
        await worker.emit(prefix)
        let queue = DesktopSettingsQueue()
        let host = try XCTUnwrap(host)
        await queue.submit { try? await host.requestOwnedRecording(requestID: owner.id) }.value
        await queue.drain()
        _ = try await phase(owner, .adopting)
        let absent = await host.ownedRecording
        XCTAssertNil(absent)
        let currentLease = await owner.lease
        let lease = try XCTUnwrap(currentLease)
        for _ in 0..<1_500 {
            if await lease.phase == .reserved { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let reserved = await lease.phase
        XCTAssertEqual(reserved, .reserved)
        let middle = pcm(1_600)
        await worker.emit(middle)
        await opening.release()
        _ = try await phase(owner, .recording)
        let descriptor = await host.ownedRecording
        XCTAssertEqual(descriptor?.requestID, owner.id)
        let tail = pcm(2_000)
        await worker.emit(tail)
        let record = try await stop(owner)
        let actual = try await payload(record)
        XCTAssertEqual(actual, prefix + middle + tail)
        XCTAssertEqual(record.recordedDuration, Double(actual.count) / 32_000)
        XCTAssertNil(record.result)
        XCTAssertTrue(record.failure?.contains("No dictation") == true)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, record.failure)
        XCTAssertFalse(FakeLog.shared.allStatuses.last?.contains("Finishing captured audio") == true)
        let recovered = try await host.store.recoverInterruptedRecordings()
        XCTAssertEqual(recovered.records.first?.failure, record.failure)
        let opens = await worker.opens
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(effects.outputs.isEmpty)
        XCTAssertFalse(FakeLog.shared.states.contains(1))
    }

    func testMemoryModelIncludesScratchAndCanonicalContextCopyAtBothRates() throws {
        for rate in [16_000, 24_000] {
            let memory = try DesktopHostOwnedPCMMemory(sampleRate: rate)
            XCTAssertEqual(memory.blockBytes, rate / 5)
            XCTAssertEqual(memory.retainedUpperBound(relayBudgetBytes: 12_800), 12_800 + 2 * rate / 5)
            var bytes = Data()
            var maximum = 0
            memory.deliver(pcm(12_800), before: { _ in }, receive: { pointer, count in
                maximum = max(maximum, count * 2)
                XCTAssertEqual(Int(bitPattern: pointer) % MemoryLayout<Int16>.alignment, 0)
                bytes.append(Data(bytes: pointer, count: count * 2))
            })
            XCTAssertEqual(bytes, pcm(12_800))
            XCTAssertLessThanOrEqual(maximum, memory.blockBytes)
        }
    }

    func testBlockedSinkBoundsAdmissionAndQueuesDrainBeforeRealClose() async throws {
        let writes = RecordingWriteGate()
        defer { writes.release() }
        let closing = RecordingGate()
        let worker = RecordingWorker(closing: closing)
        let finishing = RecordingGate(open: true)
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforePCM = { _ in try writes.pass() }
        dependency.beforeFile = { if case .finish = $0 { await finishing.pass() } }
        let owner = try await admit(dependency)
        try await promote(owner)
        await worker.emit(pcm(3_200))
        for _ in 0..<1_500 where writes.enteredCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(writes.enteredCount, 1)
        await worker.emit(pcm(9_600))
        await worker.emit(pcm(2))
        let queue = DesktopSettingsQueue()
        let host = try XCTUnwrap(host)
        await queue.submit { await host.cancelTranscription() }.value
        await queue.drain()
        let cancelled = await host.ownedRecording
        XCTAssertNil(cancelled)
        let before = await finishing.entries
        let nativeBefore = await worker.closes
        XCTAssertEqual(before, 0); XCTAssertEqual(nativeBefore, 0)
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved)
        writes.release()
        for _ in 0..<1_500 {
            if await closing.entries > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let stillBefore = await finishing.entries
        XCTAssertEqual(stillBefore, 0)
        await closing.release()
        let final = await owner.waitForRecordingOutcome()
        XCTAssertTrue(final.causes.contains(.startupOverflow))
        let record = try await host.store.record(id: final.recordID)
        let actual = try await payload(record)
        XCTAssertEqual(actual.count, 12_800)
        XCTAssertNotNil(record.failure)
    }

    func testLatchedSyntheticWriteFailureCannotBecomeHealthyAfterMorePCM() async throws {
        let worker = RecordingWorker()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforePCM = { _ in throw DesktopHostError(message: "synthetic pre-write fault") }
        let owner = try await admit(dependency)
        try await promote(owner)
        await worker.emit(pcm(6_400))
        let final = await owner.waitForRecordingOutcome()
        let record = try await host.store.record(id: final.recordID)
        XCTAssertTrue(record.failure?.contains("PCM persistence failed") == true)
        XCTAssertNil(record.result)
        let actual = try await payload(record)
        XCTAssertEqual(actual, pcm(6_400))
    }

    func testFailedNativeReleaseRetainsOwnedRetryAndCannotRefinish() async throws {
        let worker = RecordingWorker()
        await worker.configureFailure(true)
        let finishing = RecordingGate(open: true)
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { if case .finish = $0 { await finishing.pass() } }
        let owner = try await admit(dependency)
        try await promote(owner)
        await worker.emit(pcm(3_200))
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        _ = try await phase(owner, .cleanupFailed)
        let failed = await owner.snapshot()
        XCTAssertNil(failed.captureStatus)
        await owner.abort()
        let closes = await worker.closes
        let finishes = await finishing.entries
        XCTAssertEqual(closes, 1); XCTAssertEqual(finishes, 0)
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved)
        await worker.configureFailure(false)
        try await owner.retryRelease()
        let final = await owner.waitForRecordingOutcome()
        let count = await worker.closes
        let finishCount = await finishing.entries
        XCTAssertEqual(count, 2); XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(final.causes.contains { if case .cleanupFailed = $0 { return true }; return false })
    }

}

extension DesktopHostOwnedRecordingTests {
    func testNormalStopHistoryFailureRetainsCaptureDispositionAfterClose() async throws {
        let saving = RecordingGate()
        let finishing = RecordingGate(open: true)
        var dependency = DesktopHostOwnedStartupDependency(worker: RecordingWorker())
        dependency.beforeFile = {
            if case .finalSave = $0 { await saving.pass() }
            if case .finish = $0 { await finishing.pass() }
        }
        let owner = try await admit(dependency)
        try await promote(owner)
        let state = await owner.snapshot()
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        for _ in 0..<1_500 {
            if await saving.entries > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let saves = await saving.entries
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Finishing captured audio...")
        XCTAssertFalse(FakeLog.shared.allStatuses.last?.contains("abandoned") == true)
        XCTAssertFalse(FakeLog.shared.states.contains(1))
        let metadata = directory.appendingPathComponent("History").appendingPathComponent("\(state.recordID).json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        await owner.abort()
        await saving.release()
        _ = try await phase(owner, .dispositionFailed)
        for _ in 0..<1_500 {
            if FakeLog.shared.allStatuses.last?.contains("History could not be saved") == true { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let failed = await owner.snapshot()
        XCTAssertFalse(failed.captureStatus?.contains("Finishing captured audio") == true)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("History could not be saved") == true)
        XCTAssertFalse(FakeLog.shared.allStatuses.last?.contains("Finishing captured audio") == true)
        _ = await host.close()
        let closedStatuses = FakeLog.shared.allStatuses
        try FileManager.default.removeItem(at: metadata)
        try await owner.retryDisposition()
        let final = await owner.waitForRecordingOutcome()
        let record = try await host.store.record(id: final.recordID)
        XCTAssertEqual(FakeLog.shared.allStatuses, closedStatuses)
        XCTAssertTrue(record.failure?.contains("No audio signal") == true)
        let finishes = await finishing.entries
        XCTAssertEqual(finishes, 1)
    }

    func testCancelPendingPromotionAndStaleNotificationsCannotInstallRecording() async throws {
        let opening = RecordingGate()
        let worker = RecordingWorker(opening: opening)
        let owner = try await admit(.init(worker: worker))
        try await host.requestOwnedRecording(requestID: owner.id)
        _ = try await phase(owner, .adopting)
        await host.cancelTranscription()
        await opening.release()
        let old = await owner.waitForRecordingOutcome()
        let replacement = try await admit(.init(worker: RecordingWorker()))
        try await promote(replacement)
        let current = await host.ownedRecording
        await host.ownedStartupChanged(old)
        await worker.fail()
        let after = await host.ownedRecording
        XCTAssertEqual(current, after)
        await replacement.abort()
        await replacement.waitForDisposition()
    }

    func testDuplicateRequestsRevisionFenceAndOddPCMFailure() async throws {
        let worker = RecordingWorker()
        let owner = try await admit(.init(worker: worker))
        let prepared = await owner.snapshot()
        try await promote(owner)
        do { try await host.requestOwnedRecording(requestID: owner.id); XCTFail("Duplicate promotion") } catch {}
        await host.ownedStartupChanged(prepared)
        let descriptor = await host.ownedRecording
        XCTAssertNotNil(descriptor)
        await worker.emit(Data([1]))
        let final = await owner.waitForRecordingOutcome()
        XCTAssertTrue(final.causes.contains(.invalidPCM))
        let opens = await worker.opens
        XCTAssertEqual(opens, 1)
    }

    func testCloseHeldPromotionRetainsFileUntilCapabilityOwnerReturns() async throws {
        let capability = RecordingGate()
        let finishing = RecordingGate(open: true)
        let worker = RecordingWorker()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeOwnedDelivery = { await capability.pass() }
        dependency.beforeFile = { if case .finish = $0 { await finishing.pass() } }
        let owner = try await admit(dependency)
        try await host.requestOwnedRecording(requestID: owner.id)
        for _ in 0..<1_500 {
            if await capability.entries > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved)
        let finishesBefore = await finishing.entries
        XCTAssertEqual(finishesBefore, 0)
        let descriptor = await host.ownedRecording
        XCTAssertNil(descriptor)
        let statuses = FakeLog.shared.allStatuses
        await capability.release()
        let final = await owner.waitForRecordingOutcome()
        XCTAssertEqual(final.phase, .finished)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }

    func testNormalStopFinishFailureRemainsSeparateFromCapturedAudio() async throws {
        let worker = RecordingWorker()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.afterFinish = { throw DesktopHostError(message: "synthetic post-finish fault") }
        let owner = try await admit(dependency)
        try await promote(owner)
        let audio = pcm(3_200)
        await worker.emit(audio)
        let record = try await stop(owner)
        XCTAssertTrue(record.failure?.contains("Audio finalization failed") == true)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "synthetic post-finish fault")
        XCTAssertFalse(FakeLog.shared.allStatuses.last?.contains("Finishing captured audio") == true)
        XCTAssertEqual(record.recordedDuration, 0.1)
        let actual = try await payload(record)
        XCTAssertEqual(actual, audio)
        XCTAssertNil(record.result)
    }
}
