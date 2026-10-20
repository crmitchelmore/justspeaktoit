import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

private actor HostQuiescenceGate {
    private let held: Bool
    private var released = false
    private var arrived = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var departures: [CheckedContinuation<Void, Never>] = []
    init(held: Bool = false) { self.held = held }
    func pass() async {
        arrived = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if held, !released { await withCheckedContinuation { departures.append($0) } }
    }
    func wait() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() {
        released = true
        departures.forEach { $0.resume() }; departures.removeAll()
    }
}

private actor HostQuiescingWorker: DesktopPressCaptureQuiescingWorker {
    struct Failure: Error, CustomStringConvertible { let description: String }
    let quiescing = HostQuiescenceGate(held: true)
    let closing: HostQuiescenceGate
    private var receive: (@Sendable (Data) -> Void)?
    private var failure: (@Sendable (String) -> Void)?
    private let failQuiesce: Bool
    private let failDuringClose: Bool
    let expectedCloseFailures: Int
    private var closeErrors: Int
    private(set) var quiesces = 0
    private(set) var closes = 0
    init(
        closing: HostQuiescenceGate = .init(), failQuiesce: Bool = false,
        closeErrors: Int = 0, failDuringClose: Bool = false
    ) {
        self.closing = closing; self.failQuiesce = failQuiesce
        self.closeErrors = closeErrors; self.failDuringClose = failDuringClose
        self.expectedCloseFailures = closeErrors
    }
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.receive = receive; self.failure = onFailure
    }
    func quiesce(id: UUID) async throws {
        quiesces += 1
        await quiescing.pass()
        receive?(Data([3, 0]))
        if failQuiesce { throw Failure(description: "synthetic producer quiescence") }
    }
    func close(id: UUID) async throws {
        closes += 1
        await closing.pass()
        if failDuringClose { failure?("synthetic native after fence") }
        if closeErrors > 0 { closeErrors -= 1; throw Failure(description: "synthetic retirement") }
    }
    func emit(_ data: Data) { receive?(data) }
    func releaseFixtureGates() async {
        await quiescing.release()
        await closing.release()
    }
}

private actor HostQuiescenceCleanup {
    private let directory: URL
    private var host: DesktopHostController<FakePlatform>?
    private var workers: [HostQuiescingWorker] = []
    private var owners: [(DesktopHostOwnedStartup, HostQuiescingWorker)] = []
    init(directory: URL) { self.directory = directory }
    func retain(_ host: DesktopHostController<FakePlatform>) { self.host = host }
    func retain(_ worker: HostQuiescingWorker) { workers.append(worker) }
    func retain(_ owner: DesktopHostOwnedStartup, worker: HostQuiescingWorker) {
        owners.append((owner, worker))
    }
    func finish() async throws {
        for worker in workers { await worker.releaseFixtureGates() }
        for (owner, _) in owners { await owner.abort() }
        await host?.close()
        for (owner, worker) in owners {
            var retries = worker.expectedCloseFailures
            disposition: while true {
                let state = await owner.snapshot()
                switch state.phase {
                case .finished:
                    _ = await owner.waitForRecordingOutcome()
                    break disposition
                case .cleanupFailed:
                    guard retries == 1, state.cleanupFailure == .cleanupFailed("synthetic retirement") else {
                        throw DesktopHostError(
                            message: "Unexpected owned teardown cleanup: \(String(describing: state.cleanupFailure))"
                        )
                    }
                    retries -= 1
                    try await owner.retryRelease()
                case .dispositionFailed:
                    throw DesktopHostError(message: "Owned teardown disposition failed: \(state)")
                default:
                    await Task.yield()
                }
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

private actor QuiescenceFileSteps {
    private(set) var finishes = 0
    private(set) var finalSaves = 0
    func observe(_ step: DesktopHostOwnedFileStep) {
        if case .finish = step { finishes += 1 }
        if case .finalSave = step { finalSaves += 1 }
    }
}

private struct QuiescenceOnlyEffects: DesktopHostEffects {
    typealias Platform = FakePlatform
    let synthetic = SyntheticEffects()
    func apiKey(name: String) throws -> String {
        XCTFail("Owned audio must not request credentials")
        throw DesktopHostError(message: "Unexpected credential request")
    }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        XCTFail("Owned audio must not open a second legacy capture")
        throw DesktopHostError(message: "Unexpected legacy capture")
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        XCTFail("Owned audio must not create a provider")
        return nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        XCTFail("Owned audio must not transcribe")
        throw DesktopHostError(message: "Unexpected transcription")
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        XCTFail("Owned audio must not insert text")
        return synthetic.perform(job, text: text)
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

final class DesktopHostOwnedQuiescenceTests: XCTestCase {
    private var directory: URL!
    private var host: DesktopHostController<FakePlatform>!
    private var cleanup: HostQuiescenceCleanup!
    private let identity = DesktopPressCaptureIdentity(
        deviceID: "synthetic", routeID: "synthetic/audio-only", profileID: "frozen",
        sampleRate: 16_000, frameMilliseconds: 100
    )
    private let admission = DesktopPressCaptureAdmission(
        enabled: true, capability: .qualified, permission: .granted, owner: .idle
    )
    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-quiescence-\(UUID())")
        let cleanup = HostQuiescenceCleanup(directory: directory)
        self.cleanup = cleanup
        addTeardownBlock { try await cleanup.finish() }
        host = try DesktopHostController(
            directory: directory, effects: QuiescenceOnlyEffects(), shutdownGrace: .milliseconds(20)
        )
        await cleanup.retain(host)
        await host.markReadyForSelfTest()
    }
    private func phase(
        _ owner: DesktopHostOwnedStartup, _ expected: DesktopHostOwnedStartupSnapshot.Phase
    ) async throws {
        for _ in 0..<1_500 {
            if await owner.snapshot().phase == expected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Did not reach \(expected)")
    }
    private func admit(
        _ worker: HostQuiescingWorker, steps: QuiescenceFileSteps
    ) async throws -> DesktopHostOwnedStartup {
        await cleanup.retain(worker)
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { await steps.observe($0) }
        let owner = try await host.admitOwnedCaptureStartup(
            identity: identity, admission: admission,
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 1_600, reservedFrames: 3_200),
            dependency: dependency
        )
        await cleanup.retain(owner, worker: worker)
        try await phase(owner, .prepared)
        try await host.requestOwnedRecording(requestID: owner.id)
        try await phase(owner, .recording)
        return owner
    }
    private func payload(_ record: DesktopRecordingStore.Record) async throws -> Data {
        let url = try await host.store.audioURL(for: record)
        return Data(try Data(contentsOf: url).dropFirst(44))
    }
    private func assertNoDisposition(_ steps: QuiescenceFileSteps) async {
        let finishes = await steps.finishes
        let saves = await steps.finalSaves
        XCTAssertEqual(finishes, 0); XCTAssertEqual(saves, 0)
    }

    func testHeldQuiescenceAndRetirementBlockWAVFinishAndHistorySaveWithoutBlockingAdmission() async throws {
        let closing = HostQuiescenceGate(held: true)
        let worker = HostQuiescingWorker(closing: closing)
        let steps = QuiescenceFileSteps()
        let owner = try await admit(worker, steps: steps)
        await worker.emit(Data([1, 0, 2, 0]))
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        await worker.quiescing.wait()
        await assertNoDisposition(steps)
        let before = await worker.closes
        XCTAssertEqual(before, 0)
        XCTAssertFalse(FakeLog.shared.allStatuses.last?.contains("abandoned") == true)
        let queue = DesktopSettingsQueue()
        let controller = try XCTUnwrap(host)
        await queue.submit { _ = await controller.ownedRecording }.value
        await queue.drain()
        await worker.quiescing.release()
        await closing.wait()
        await assertNoDisposition(steps)
        await closing.release()
        let outcome = await owner.waitForRecordingOutcome()
        let record = try await host.store.record(id: outcome.recordID)
        let actual = try await payload(record)
        XCTAssertEqual(actual, Data([1, 0, 2, 0, 3, 0]))
        XCTAssertEqual(record.recordedDuration, 3.0 / 16_000)
        XCTAssertTrue(record.failure?.contains("No dictation") == true)
        XCTAssertNil(record.result); XCTAssertTrue(outcome.causes.isEmpty)
        let finishes = await steps.finishes
        let saves = await steps.finalSaves
        XCTAssertEqual(finishes, 1); XCTAssertEqual(saves, 1)
        XCTAssertFalse(FakeLog.shared.states.contains(1))
    }

    func testClosedHostRetainsHeldQuiescenceAndLateNativeFailureWithoutPresenting() async throws {
        let worker = HostQuiescingWorker(failDuringClose: true)
        let steps = QuiescenceFileSteps()
        let owner = try await admit(worker, steps: steps)
        await worker.emit(Data([1, 0]))
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        await worker.quiescing.wait()
        let report = await host.close()
        XCTAssertFalse(report.recordingSaved)
        await assertNoDisposition(steps)
        let statuses = FakeLog.shared.allStatuses
        await worker.quiescing.release()
        let outcome = await owner.waitForRecordingOutcome()
        XCTAssertEqual(outcome.causes, [.captureFailed("synthetic native after fence")])
        let record = try await host.store.record(id: outcome.recordID)
        let actual = try await payload(record)
        XCTAssertEqual(actual, Data([1, 0, 3, 0]))
        XCTAssertTrue(record.failure?.contains("synthetic native after fence") == true)
        XCTAssertFalse(record.failure?.contains("Audio captured.") == true)
        XCTAssertNil(record.result)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertFalse(FakeLog.shared.states.contains(1))
    }

    func testFailedQuiesceAndRetirementRetainOwnerUntilOwnedRetryAndSaveFailureTruth() async throws {
        let worker = HostQuiescingWorker(failQuiesce: true, closeErrors: 1)
        let steps = QuiescenceFileSteps()
        let owner = try await admit(worker, steps: steps)
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        await worker.quiescing.wait()
        await worker.quiescing.release()
        try await phase(owner, .cleanupFailed)
        await assertNoDisposition(steps)
        do {
            _ = try await host.admitOwnedCaptureStartup(
                identity: identity, admission: admission,
                limits: DesktopPressCaptureBufferLimits(preRollFrames: 1, reservedFrames: 2),
                dependency: .init(worker: worker)
            )
            XCTFail("Failed retirement must retain exclusion")
        } catch {
            XCTAssertEqual(error as? DesktopPressCaptureError, .occupied)
        }
        try await owner.retryRelease()
        let outcome = await owner.waitForRecordingOutcome()
        XCTAssertTrue(outcome.causes.contains(.captureFailed(
            "Producer quiescence failed: synthetic producer quiescence"
        )))
        let record = try await host.store.record(id: outcome.recordID)
        let actual = try await payload(record)
        XCTAssertEqual(actual, Data([3, 0]))
        XCTAssertTrue(record.failure?.contains("synthetic producer quiescence") == true)
        XCTAssertFalse(record.failure?.contains("Audio captured.") == true)
        XCTAssertNil(record.result)
        let quiesces = await worker.quiesces
        let closes = await worker.closes
        let finishes = await steps.finishes
        XCTAssertEqual(quiesces, 1); XCTAssertEqual(closes, 2); XCTAssertEqual(finishes, 1)
        XCTAssertFalse(FakeLog.shared.states.contains(1))
    }
}
