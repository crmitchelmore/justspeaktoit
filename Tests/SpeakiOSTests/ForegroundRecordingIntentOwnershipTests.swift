#if os(iOS)
import AppIntents
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@available(iOS 18, *)
@MainActor
final class ForegroundRecordingIntentOwnershipTests: XCTestCase {
    func testControlAndStartIntents_refuseForegroundStartupUnwindAndStop() async throws {
        let ownership = ForegroundRecordingOwnership.shared
        XCTAssertFalse(ownership.isOwned)
        let backend = ForegroundTestSuspension("startup")
        let session = ForegroundTestSession()
        session.startOperation = backend.wait
        let coordinator = makeForegroundTestCoordinator(
            historyManager: makeForegroundTestHistory(), ownership: ownership, session: { session }
        )
        let start = Task { try await coordinator.start() }
        await fulfillment(of: [backend.entered], timeout: 2)
        await assertIntentsRefuseForeground()
        coordinator.cancel()
        await assertIntentsRefuseForeground()
        backend.release()
        _ = await start.result
        XCTAssertFalse(ownership.isOwned)

        session.startOperation = {}
        try await coordinator.start()
        let drain = ForegroundTestSuspension("finalisation")
        session.stopOperation = {
            await drain.wait()
            return ForegroundTestSession.result("finished")
        }
        let stop = Task { await coordinator.stop() }
        await fulfillment(of: [drain.entered], timeout: 2)
        await assertIntentsRefuseForeground()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(session.cancellations, 1)
        drain.release()
        _ = await stop.value
        XCTAssertFalse(ownership.isOwned)
        try await coordinator.start()
        await coordinator.cancelAndWait()
    }

    func testHeadlessAcquisition_rechecksOwnershipAfterCredentialsAndDoesNotPublishState() async throws {
        let suite = "ForegroundAcquisition.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let shared = SharedTranscriptionState(defaults: defaults)
        shared.updateTranscript("previous transcript")
        let ownership = ForegroundRecordingOwnership()
        let credentials = ForegroundTestSuspension("headless credentials")
        var firstLoad = true
        let service = TranscriptionRecordingService(
            sharedState: shared,
            historyManager: iOSHistoryManager(fileURL: directory.appendingPathComponent("history.json"),
                                             syncEnabled: false, userDefaults: defaults),
            polishClipboard: PolishClipboard(), hasPolishingKey: { false }, polish: { text, _, _ in text },
            foregroundOwnership: ownership, ensureKeysLoaded: {
                if firstLoad {
                    firstLoad = false
                    await credentials.wait()
                }
            }
        )
        // An intent's earlier preflight cannot authorise later acquisition.
        XCTAssertNoThrow(try ownership.requireUnowned())
        let start = Task { try await service.startRecording() }
        await fulfillment(of: [credentials.entered], timeout: 2)
        let foregroundRun = UUID()
        XCTAssertTrue(ownership.claim(foregroundRun))
        credentials.release()
        do {
            try await start.value
            XCTFail("Late foreground claim must reject acquisition")
        } catch { XCTAssertTrue(error is ForegroundRecordingOwnership.OwnershipError) }
        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(shared.isRecording)
        XCTAssertEqual(shared.currentTranscriptText, "previous transcript")
        XCTAssertTrue(ownership.isOwned)
        // Subsequent direct service starts also reject before touching resources.
        do {
            try await service.startRecording()
            XCTFail("Existing foreground ownership must reject acquisition")
        } catch { XCTAssertTrue(error is ForegroundRecordingOwnership.OwnershipError) }
        ownership.release(foregroundRun)
        XCTAssertNoThrow(try ownership.requireUnowned())
        try await assertFreshHeadlessCapture(service, defaults: defaults)
    }

    private func assertFreshHeadlessCapture(
        _ service: TranscriptionRecordingService, defaults: UserDefaults
    ) async throws {
        #if DEBUG && targetEnvironment(simulator)
        defaults.set("fresh headless capture", forKey: "simulatorValidationTranscript")
        try await service.startRecording(requiresLiveActivity: false)
        XCTAssertTrue(service.isRunning)
        service.cancelRecording()
        XCTAssertEqual(service.state, .idle)
        #endif
    }

    func testDisplayFlag_staysSeparateFromOwnershipUntilFinalTeardown() async throws {
        let suite = "ForegroundDisplay.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shared = SharedTranscriptionState(defaults: defaults)
        let ownership = ForegroundRecordingOwnership()
        let session = ForegroundTestSession()
        let backend = ForegroundTestSuspension("display startup")
        session.startOperation = backend.wait
        let coordinator = makeForegroundTestCoordinator(
            sharedState: shared, historyManager: makeForegroundTestHistory(),
            ownership: ownership, session: { session }
        )
        let start = Task { try await coordinator.start() }
        await fulfillment(of: [backend.entered], timeout: 2)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertFalse(shared.isRecording)
        backend.release()
        try await start.value
        XCTAssertTrue(shared.isRecording)
        let drain = ForegroundTestSuspension("display stop")
        session.stopOperation = {
            await drain.wait()
            return ForegroundTestSession.result("final shared words")
        }
        let stop = Task { await coordinator.stop() }
        await fulfillment(of: [drain.entered], timeout: 2)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertFalse(shared.isRecording)
        drain.release()
        _ = await stop.value
        session.onPartialResult?("late stale words", true)
        session.onError?(iOSTranscriptionError.microphoneChanged)
        XCTAssertFalse(ownership.isOwned)
        XCTAssertFalse(shared.isRecording)
        XCTAssertEqual(shared.currentTranscriptText, "final shared words")
        XCTAssertNil(coordinator.error)
    }

    func testActiveCancellation_holdsOwnershipUntilBackendCleanupSettles() async throws {
        let cleanup = ForegroundTestSuspension("cancel cleanup")
        let session = ForegroundTestSession()
        session.cancellationSettlement = cleanup.wait
        let ownership = ForegroundRecordingOwnership.shared
        let history = makeForegroundTestHistory()
        let coordinator = makeForegroundTestCoordinator(
            historyManager: history, ownership: ownership, session: { session }
        )
        try await coordinator.start()
        let cancellation = Task { await coordinator.cancelAndWait() }
        await fulfillment(of: [cleanup.entered], timeout: 2)
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertFalse(coordinator.isRunning)
        await assertIntentsRefuseForeground()
        session.onPartialResult?("discarded", true)
        session.onError?(iOSTranscriptionError.microphoneChanged)
        XCTAssertTrue(coordinator.partialText.isEmpty)
        XCTAssertNil(coordinator.error)
        do {
            try await coordinator.start()
            XCTFail("Replacement must await owned cleanup")
        } catch { }
        cleanup.release()
        await cancellation.value
        XCTAssertFalse(ownership.isOwned)
        session.cancellationSettlement = {}
        try await coordinator.start()
        await coordinator.cancelAndWait()
        XCTAssertTrue(history.items.isEmpty, "Cancel must not save History")
    }

    private func assertIntentsRefuseForeground() async {
        for value in [true, false] {
            var control = ToggleTranscriptionControlIntent()
            control.value = value
            do {
                _ = try await control.perform()
                XCTFail("Control \(value) must not report success for the foreground owner")
            } catch { XCTAssertTrue(error is ForegroundRecordingOwnership.OwnershipError) }
        }
        do {
            _ = try await StartTranscriptionRecordingIntent().perform()
            XCTFail("Toggle must not start a headless session")
        } catch { }
        // Start and Stop return the existing foreign-owner guidance instead of throwing.
        _ = try? await StartTranscriptionIntent().perform()
        _ = try? await StopTranscriptionRecordingIntent().perform()
        XCTAssertEqual(TranscriptionRecordingService.shared.state, .idle)
        XCTAssertTrue(ForegroundRecordingOwnership.shared.isOwned)
    }
}
#endif
