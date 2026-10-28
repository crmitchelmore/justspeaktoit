#if os(iOS) && DEBUG && targetEnvironment(simulator)
import AVFoundation
import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakiOSLib

@available(iOS 18, *)
@MainActor
final class CaptureStartupWatchdogDiagnosticTests: XCTestCase {
    func testRealWatchdogTickPreservesTimeoutThroughCancelledSessionAndIntentJournal() async throws {
        let run = try StartupDiagnosticRun()
        addTeardownBlock { @MainActor in await run.cleanUp() }
        run.start(entry: StartupEntry(origin: .startIntent, observedAt: Date().addingTimeInterval(-61)))
        guard await self.completed(run.session.entered, timeout: 2) else { return }
        guard await self.completed(run.done, timeout: 4) else { return }
        XCTAssertTrue(run.error is CancellationError, "Cleanup cancellation still propagates to the caller")
        guard case .startTimedOut = run.service.lastSessionError as? iOSTranscriptionError else {
            return XCTFail("The actual watchdog must publish its real typed cause")
        }
        XCTAssertEqual(run.activity.codes, ["start_timeout"])
        XCTAssertEqual(run.activity.neutralEnds, 0)
        XCTAssertEqual(run.service.state, .idle)
        XCTAssertEqual(run.harness.defaults.string(forKey: "captureHealth.lastOutcome.v1"), "startFailed")
        XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: run.harness.defaults), "start_timeout")
        XCTAssertGreaterThanOrEqual(run.session.cancellations, 1)

        // The next real admission cannot inherit this timeout receipt.
        run.service.makeSession = { throw iOSTranscriptionError.permissionDenied(.speechRecognition) }
        do {
            try await run.startAnotherAttempt()
            XCTFail("The replacement's own failure must propagate")
        } catch {}
        XCTAssertEqual(
            CaptureOutcomeJournal.lastFailureCode(defaults: run.harness.defaults),
            "start_permission_speech_recognition"
        )
        XCTAssertEqual(run.activity.codes, ["start_timeout", "start_permission_speech_recognition"])
    }

    func testWatchdogCauseSurvivesSessionReturningNormallyAfterItsCancellation() async throws {
        let run = try StartupDiagnosticRun()
        run.session.returnsNormallyOnCancel = true
        addTeardownBlock { @MainActor in await run.cleanUp() }
        run.start(entry: StartupEntry(origin: .startIntent, observedAt: Date().addingTimeInterval(-61)))
        guard await self.completed(run.session.entered, timeout: 2) else { return }
        guard await self.completed(run.done, timeout: 4) else { return }
        XCTAssertTrue(run.error is CancellationError)
        XCTAssertEqual(run.activity.codes, ["start_timeout"])
        XCTAssertEqual(run.activity.neutralEnds, 0, "Only the catch owns this startup's unwind")
        XCTAssertFalse(run.service.isRunning)
        XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: run.harness.defaults), "start_timeout")
    }

    func testPlainCancellationOfHeldStartupStaysNeutral() async throws {
        let run = try StartupDiagnosticRun()
        addTeardownBlock { @MainActor in await run.cleanUp() }
        run.start(entry: StartupEntry(origin: .startIntent))
        guard await self.completed(run.session.entered, timeout: 2) else { return }
        run.service.cancelRecording()
        guard await self.completed(run.done, timeout: 2) else { return }
        XCTAssertTrue(run.error is CancellationError)
        XCTAssertTrue(run.activity.codes.isEmpty)
        XCTAssertEqual(run.activity.neutralEnds, 1)
        XCTAssertEqual(run.harness.defaults.string(forKey: "captureHealth.lastOutcome.v1"), "cancelled")
        XCTAssertNil(CaptureOutcomeJournal.lastFailureCode(defaults: run.harness.defaults))
        XCTAssertNil(run.service.lastSessionError)
    }

    func testForegroundClaimDuringWatchdogCancellationCannotReceiveOldFailureMetadata() async throws {
        let run = try StartupDiagnosticRun()
        let owner = UUID()
        run.session.onCancel = { XCTAssertTrue(run.ownership.claim(owner)) }
        addTeardownBlock { @MainActor in
            run.session.onCancel = nil
            await run.cleanUp()
            run.ownership.release(owner)
        }
        run.start(entry: StartupEntry(origin: .startIntent, observedAt: Date().addingTimeInterval(-61)))
        guard await self.completed(run.session.entered, timeout: 2) else { return }
        guard await self.completed(run.done, timeout: 4) else { return }
        XCTAssertTrue(run.ownership.isOwned)
        XCTAssertTrue(run.activity.codes.isEmpty)
        XCTAssertEqual(run.activity.neutralEnds, 1)
        XCTAssertTrue(run.error is CancellationError)
    }

    func testNoInputWatchdogKeepsItsTypedCauseWhenStartupIsCancelled() async throws {
        let run = try StartupDiagnosticRun()
        addTeardownBlock { @MainActor in await run.cleanUp() }
        run.start(entry: StartupEntry(origin: .startIntent))
        guard await self.completed(run.session.entered, timeout: 2) else { return }
        // Only this fixture's existing monitor seam has an immediate no-input bound.
        // The actual one-second service tick and typed trip/cancellation path run unchanged.
        run.service.watchdog = CaptureWatchdogMonitor(CaptureWatchdogBudget(firstInputDeadline: 0))
        run.session.onStartupObservation?(.stage(.engineStarted))
        guard await self.completed(run.done, timeout: 4) else { return }
        XCTAssertTrue(run.error is CancellationError)
        XCTAssertEqual(run.activity.codes, ["start_no_audio"])
        XCTAssertEqual(run.harness.defaults.string(forKey: "captureHealth.lastOutcome.v1"), "noInput")
        XCTAssertEqual(CaptureOutcomeJournal.lastFailureCode(defaults: run.harness.defaults), "start_no_audio")
    }

    private func completed(_ receipt: XCTestExpectation, timeout: TimeInterval) async -> Bool {
        let completed = await XCTWaiter.fulfillment(of: [receipt], timeout: timeout) == .completed
        if !completed { XCTFail("Owned startup did not reach its bounded receipt: \(receipt.expectationDescription)") }
        return completed
    }
}

@available(iOS 18, *)
@MainActor
private final class StartupDiagnosticRun {
    let harness: DependencyHarness
    let ownership: ForegroundRecordingOwnership
    let activity: StartupDiagnosticActivity
    let session: StartupDiagnosticSession
    let service: TranscriptionRecordingService
    let done = XCTestExpectation(description: "owned intent operation finished")
    let exited = XCTestExpectation(description: "owned intent task exited")
    var error: Error?
    private var task: Task<Void, Never>?

    init() throws {
        let harness = try DependencyHarness()
        let ownership = ForegroundRecordingOwnership()
        let activity = StartupDiagnosticActivity()
        let session = StartupDiagnosticSession()
        self.harness = harness
        self.ownership = ownership
        self.activity = activity
        self.session = session
        self.service = harness.makeService(activity: RecordingServiceActivity(
            start: { _, _ in true }, update: { _, _, _, _ in },
            endActivity: { activity.neutralEnds += 1 }, reportError: { _ in },
            complete: { _, _, _, _, _, _, _ in },
            endFailedActivity: { _, code in activity.codes.append(code) }
        ), foregroundOwnership: ownership)
        self.service.makeSession = { session }
    }

    func start(entry: StartupEntry) {
        self.task = Task {
            defer { self.exited.fulfill() }
            do { try await self.startAnotherAttempt(entry: entry) } catch { self.error = error }
            self.done.fulfill()
        }
    }

    func startAnotherAttempt(entry: StartupEntry = StartupEntry(origin: .startIntent)) async throws {
        try await startRecordingWithForegroundRecovery(service: self.service, start: { request in
            try await self.service.startRecording(destination: nil, entry: entry, configurationRequest: request)
        }, continueInForeground: { _ in XCTFail("A watchdog failure must not request foreground recovery") })
    }

    func cleanUp() async {
        self.service.cancelRecording()
        self.session.cancel()
        self.task?.cancel()
        if self.task != nil {
            guard await XCTWaiter.fulfillment(of: [self.exited], timeout: 2) == .completed else {
                return XCTFail("Unsettled owned startup; retained fixture directory: \(self.harness.directory.path)")
            }
        }
        self.task = nil
        self.session.onPartialResult = nil
        self.session.onError = nil
        self.session.onFirstInputBuffer = nil
        self.session.onStartupObservation = nil
        self.session.onRecordingWarning = nil
        self.session.onCancel = nil
        self.harness.cleanUp()
    }
}

@MainActor
private final class StartupDiagnosticActivity {
    var codes: [String] = []
    var neutralEnds = 0
}

@MainActor
private final class StartupDiagnosticSession: IOSRecordingSession {
    let entered = XCTestExpectation(description: "actual session start is held")
    let isBatch = false
    let stopCompletionTimeout: TimeInterval = 1
    let resolution = IOSTranscriptionSession.Resolution(modelID: "test", backend: .apple, route: nil)
    let partialText = ""
    let confidence: Double? = nil
    let inputLevelSample = CaptureInputLevelSample(levelDBFS: -160, sequence: 0)
    let safetyRecordingID: UUID? = nil
    let recordingLossSummary: String? = nil
    var onPartialResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onFirstInputBuffer: (() -> Void)?
    var onStartupObservation: ((StartupObservation) -> Void)?
    var onRecordingWarning: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var returnsNormallyOnCancel = false
    var cancellations = 0
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?

    func resetInputLevel() {}
    func discardTemporaryRecording() -> Bool { false }
    func awaitCancellationSettled() async {}
    func start(preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool) async throws {
        try await self.start()
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.entered.fulfill()
            if self.cancelled { self.resume() }
        }
    }
    func stop() async throws -> TranscriptionResult { throw CancellationError() }
    func cancel() {
        self.cancellations += 1
        if !self.cancelled { self.onCancel?() }
        self.cancelled = true
        self.resume()
    }
    private func resume() {
        let continuation = self.continuation
        self.continuation = nil
        if self.returnsNormallyOnCancel { continuation?.resume() } else {
            continuation?.resume(throwing: CancellationError())
        }
    }
}
#endif
