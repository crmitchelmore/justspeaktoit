#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class ForegroundRecordingCoordinatorTests: XCTestCase {
    func testCredentialWait_duplicateAutoAndDirectStartsCannotAcquire_manualStopWaitsForUnwind() async throws {
        let credentials = ForegroundTestSuspension("credentials")
        let ownership = ForegroundRecordingOwnership()
        let history = makeForegroundTestHistory()
        var allocations = 0
        let coordinator = makeCoordinator(
            ownership: ownership, history: history, credentials: credentials.wait
        ) {
            allocations += 1
            return ForegroundTestSession()
        }
        let autoStart = Task { try await coordinator.start() }
        await fulfillment(of: [credentials.entered], timeout: 2)
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(ownership.isOwned)
        await assertStartRejected(coordinator)
        let stopped = expectation(description: "manual stop settled")
        let cancelling = expectation(description: "manual cancellation issued")
        let stop = Task {
            coordinator.cancel()
            cancelling.fulfill()
            let result = await coordinator.stop()
            XCTAssertTrue(result.text.isEmpty)
            stopped.fulfill()
        }
        await fulfillment(of: [cancelling], timeout: 2)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertNotEqual(coordinator.state, .idle)
        await assertStartRejected(coordinator)
        credentials.release()
        await assertCancelled(autoStart)
        await fulfillment(of: [stopped], timeout: 2)
        await stop.value
        XCTAssertEqual(allocations, 0)
        XCTAssertFalse(ownership.isOwned)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.error)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testBackendCancel_lateCallbacksAreIgnoredAndReplacementWaitsForSettlement() async throws {
        let backend = ForegroundTestSuspension("backend startup")
        let first = ForegroundTestSession()
        first.startOperation = backend.wait
        let next = ForegroundTestSession()
        let ownership = ForegroundRecordingOwnership()
        let history = makeForegroundTestHistory()
        var allocations = 0
        let coordinator = makeCoordinator(ownership: ownership, history: history) {
            allocations += 1
            return allocations == 1 ? first : next
        }
        let start = Task { try await coordinator.start() }
        await fulfillment(of: [backend.entered], timeout: 2)
        let oldPartial = first.onPartialResult
        let oldError = first.onError
        coordinator.cancel()
        XCTAssertEqual(first.cancellations, 1)
        XCTAssertEqual(coordinator.state, .stopping)
        oldPartial?("cancelled words", false)
        oldError?(iOSTranscriptionError.microphoneChanged)
        XCTAssertTrue(coordinator.partialText.isEmpty)
        XCTAssertNil(coordinator.error)
        await assertStartRejected(coordinator)
        XCTAssertTrue(ownership.isOwned)
        backend.release()
        await assertCancelled(start)
        try await coordinator.start()
        next.onPartialResult?("new words", false)
        oldPartial?("stale words", true)
        oldError?(iOSTranscriptionError.microphoneChanged)
        XCTAssertEqual(coordinator.partialText, "new words")
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(next.cancellations, 0)
        await coordinator.cancelAndWait()
        XCTAssertFalse(ownership.isOwned)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testParentTaskCancellation_doesNotActivateAfterBackendResumes() async {
        let backend = ForegroundTestSuspension("backend")
        let session = ForegroundTestSession()
        session.startOperation = backend.wait
        let ownership = ForegroundRecordingOwnership()
        let history = makeForegroundTestHistory()
        let coordinator = makeCoordinator(ownership: ownership, history: history) { session }
        let start = Task { try await coordinator.start() }
        await fulfillment(of: [backend.entered], timeout: 2)
        start.cancel()
        session.onError?(iOSTranscriptionError.recognizerUnavailable)
        XCTAssertNil(coordinator.error)
        XCTAssertTrue(ownership.isOwned)
        backend.release()
        await assertCancelled(start)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.error)
        XCTAssertGreaterThan(session.cancellations, 0)
        XCTAssertFalse(ownership.isOwned)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testConstructionAndBackendFailures_releaseOwnershipAndAllowRestart() async throws {
        for constructionFails in [true, false] {
            let ownership = ForegroundRecordingOwnership()
            let history = makeForegroundTestHistory()
            var shouldFail = true
            let session = ForegroundTestSession()
            session.startOperation = {
                if shouldFail { throw iOSTranscriptionError.permissionDenied(.microphone) }
            }
            let coordinator = makeCoordinator(ownership: ownership, history: history) {
                if shouldFail && constructionFails { throw iOSTranscriptionError.permissionDenied(.microphone) }
                return session
            }
            await assertStartRejected(coordinator)
            XCTAssertFalse(ownership.isOwned)
            XCTAssertEqual(coordinator.state, .idle)
            shouldFail = false
            try await coordinator.start()
            XCTAssertTrue(coordinator.isRunning)
            await coordinator.cancelAndWait()
            XCTAssertTrue(history.items.isEmpty)
        }
    }

    func testStop_preservesCurrentCallbacksAndOneHistoryResultWhileRejectingNewStarts() async throws {
        let draining = ForegroundTestSuspension("stop drain")
        let ownership = ForegroundRecordingOwnership()
        let session = ForegroundTestSession()
        session.stopOperation = {
            await draining.wait()
            return ForegroundTestSession.result("")
        }
        let history = makeForegroundTestHistory()
        let coordinator = makeCoordinator(ownership: ownership, history: history) { session }
        try await coordinator.start()
        let stop = Task { await coordinator.stop() }
        await fulfillment(of: [draining.entered], timeout: 2)
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(ownership.isOwned)
        session.onPartialResult?("last captured words", true)
        await assertStartRejected(coordinator)
        let duplicate = await coordinator.stop()
        XCTAssertTrue(duplicate.text.isEmpty)
        XCTAssertEqual(session.cancellations, 0)
        XCTAssertEqual(session.stops, 1)
        draining.release()
        let result = await stop.value
        XCTAssertEqual(result.text, "last captured words")
        XCTAssertEqual(history.items.map(\.transcription), ["last captured words"])
        XCTAssertFalse(ownership.isOwned)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testHeadlessServiceBusy_foregroundCannotAcquireBeforeCredentials() async {
        for state: RecordingServiceState in [.starting, .recording, .stopping] {
            let coordinator = makeForegroundTestCoordinator(
                historyManager: makeForegroundTestHistory(),
                ownership: ForegroundRecordingOwnership(),
                ensureKeysLoaded: { XCTFail("must reject before credentials") },
                headlessState: { state },
                session: { XCTFail("must reject before allocating"); return ForegroundTestSession() }
            )
            await assertStartRejected(coordinator)
        }
    }

    func testHandsFreeHandle_rejectedStartAndLateCancelCannotAffectForegroundCapture() async throws {
        let ownership = ForegroundRecordingOwnership()
        let history = makeForegroundTestHistory()
        let session = ForegroundTestSession()
        let coordinator = makeCoordinator(ownership: ownership, history: history) { session }
        let handsFree = ForegroundCaptureHandle()
        try await coordinator.start(handle: handsFree)
        coordinator.cancel(handle: handsFree)
        await coordinator.cancelAndWait()
        try await coordinator.start()
        do {
            try await coordinator.start(handle: handsFree)
            XCTFail("Hands-free must receive a rejected start")
        } catch { }
        coordinator.cancel(handle: handsFree)
        let staleStop = await coordinator.stop(handle: handsFree, rearmHandsFree: { true })
        XCTAssertTrue(staleStop.text.isEmpty)
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(session.cancellations, 1)
        XCTAssertEqual(session.stops, 0)
        await coordinator.cancelAndWait()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testHandsFreeHandle_cancelsItsPendingStartup() async {
        let backend = ForegroundTestSuspension("hands-free start")
        let session = ForegroundTestSession()
        session.startOperation = backend.wait
        let ownership = ForegroundRecordingOwnership()
        let history = makeForegroundTestHistory()
        let coordinator = makeCoordinator(ownership: ownership, history: history) { session }
        let handsFree = ForegroundCaptureHandle()
        let start = Task { try await coordinator.start(handle: handsFree) }
        await fulfillment(of: [backend.entered], timeout: 2)
        coordinator.cancel(handle: handsFree)
        XCTAssertEqual(session.cancellations, 1)
        XCTAssertTrue(ownership.isOwned)
        backend.release()
        await assertCancelled(start)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(ownership.isOwned)
        XCTAssertTrue(history.items.isEmpty)
    }

    private func makeCoordinator(
        ownership: ForegroundRecordingOwnership,
        history: iOSHistoryManager,
        credentials: @escaping @MainActor () async -> Void = {},
        session: @escaping @MainActor () throws -> any IOSRecordingSession
    ) -> TranscriberCoordinator {
        makeForegroundTestCoordinator(
            historyManager: history, ownership: ownership,
            ensureKeysLoaded: credentials, session: session
        )
    }

    private func assertStartRejected(_ coordinator: TranscriberCoordinator) async {
        do {
            try await coordinator.start()
            XCTFail("Duplicate or failed start must not report success")
        } catch { }
    }

    private func assertCancelled(_ start: Task<Void, Error>) async {
        do {
            try await start.value
            XCTFail("Startup should be cancelled")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}
#endif
