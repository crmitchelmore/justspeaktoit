import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class SharedClientLiveControllerRecoveryTests: XCTestCase {
    func testQueuedPrimaryErrorArrivesBeforeStopReturnsAndIsNeverReportedAsSuccess() async throws {
        let fixture = Fixture()
        fixture.client.finish = {
            fixture.client.failure?(Failure())
            return "confirmed"
        }
        try await fixture.controller.start()
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.errors.first is Failure)
        XCTAssertTrue(fixture.delegate.results.isEmpty, "A failed stream must not publish terminal success")
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1)
    }

    func testFailedFinishRetainsVisibleDraftWhenConfirmationIsRevised() async throws {
        let fixture = Fixture()
        try await fixture.controller.start()
        fixture.client.transcript?("Hello", true)
        fixture.client.transcript?("Hello trailing words", false)
        fixture.updates.deliverAll()
        fixture.client.finish = {
            fixture.client.failure?(Failure())
            return "Hello, revised."
        }
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.partials.last, "Hello trailing words")
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
    }

    func testHealthyWholeReturnIsAuthoritativeAndQueuedCallbacksCannotRewindIt() async throws {
        let fixture = Fixture()
        try await fixture.controller.start()
        fixture.client.transcript?("earlier draft", false)
        fixture.client.finish = { "Final punctuation!" }
        await fixture.controller.stop()
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["Final punctuation!"])
        XCTAssertEqual(fixture.delegate.partials, ["Final punctuation!"])
        XCTAssertEqual(fixture.delegate.boundaries, ["Final punctuation!"])
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testNilFinishKeepsQueuedDraftAndStandaloneRepeatsRemainDistinct() async throws {
        let fixture = Fixture()
        fixture.client.finalShape = .standaloneSegments
        try await fixture.controller.start()
        fixture.client.transcript?("Yes", true)
        fixture.client.transcript?("Yes", true)
        fixture.client.transcript?("trailing words", false)
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.results.last?.text, "Yes Yes trailing words")
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testAlreadyPublishedFinalDoesNotTriggerAnotherUtteranceAtStop() async throws {
        let fixture = Fixture()
        try await fixture.controller.start()
        fixture.client.transcript?("Complete", true)
        fixture.updates.deliverAll()
        fixture.client.finish = { "Complete" }
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.boundaries, ["Complete"])
        XCTAssertEqual(fixture.delegate.results.last?.text, "Complete")
    }

    func testCancelledFinishAbortsPromptlyAndCannotOverlapAReplacement() async throws {
        let fixture = Fixture()
        let finishing = expectation(description: "provider awaiting cancellation")
        var finish: CheckedContinuation<String?, Never>?
        fixture.client.finish = {
            await withCheckedContinuation { finish = $0; finishing.fulfill() }
        }
        fixture.client.abort = { finish?.resume(returning: "Hello, revised."); finish = nil }
        try await fixture.controller.start()
        fixture.client.transcript?("Hello", true)
        fixture.client.transcript?("Hello trailing words", false)
        fixture.updates.deliverAll()
        let stopping = Task { await fixture.controller.stop() }
        await fulfillment(of: [finishing], timeout: 2)
        do {
            try await fixture.controller.start()
            XCTFail("A pending finalisation must retain controller ownership")
        } catch {
            XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionAlreadyRunning)
        }
        stopping.cancel()
        await stopping.value
        XCTAssertEqual(fixture.client.cancellations, 1)
        XCTAssertTrue(fixture.delegate.errors.last is CancellationError)
        XCTAssertEqual(fixture.delegate.partials.last, "Hello trailing words")
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        fixture.client.finish = nil
        fixture.client.abort = nil
        try await fixture.controller.start()
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.results.map(\.text), [""])
    }

    func testTerminalDelegateCancellationCannotPublishSuccess() async throws {
        let fixture = Fixture()
        let finishing = expectation(description: "provider awaits final transcript")
        var finish: CheckedContinuation<String?, Never>?
        fixture.client.finish = {
            await withCheckedContinuation { finish = $0; finishing.fulfill() }
        }
        try await fixture.controller.start()
        let stopping = Task { await fixture.controller.stop() }
        await fulfillment(of: [finishing], timeout: 2)
        fixture.delegate.onPartial = { stopping.cancel() }
        finish?.resume(returning: "Final transcript")
        finish = nil
        await stopping.value
        XCTAssertTrue(fixture.delegate.results.isEmpty, "A delegate-cancelled stop must not publish success")
        XCTAssertTrue(fixture.delegate.errors.last is CancellationError)
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertEqual(fixture.delegate.partials.last, "Final transcript")
        XCTAssertTrue(fixture.delegate.boundaries.isEmpty, "Cancelled terminal text must not trigger utterance work")
    }

    func testOldCallbacksCannotChangeReplacementAndModelIdentityIsFrozen() async throws {
        let fixture = Fixture()
        try await fixture.controller.start()
        let oldTranscript = fixture.client.transcript
        let oldFailure = fixture.client.failure
        fixture.client.transcript?("old", false)
        await fixture.controller.stop()
        try await fixture.controller.start()
        fixture.controller.configure(language: nil, model: "speechmatics/changed-while-recording")
        oldTranscript?("stale", true)
        oldFailure?(Failure())
        fixture.client.transcript?("replacement", false)
        fixture.updates.deliverAll()
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.results.last?.text, "replacement")
        XCTAssertEqual(fixture.delegate.results.last?.modelIdentifier, XAISpeechToText.liveCatalogID)
        XCTAssertFalse(fixture.delegate.partials.contains("stale"))
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testSynchronousStartupFailurePreventsCaptureAndReleasesRun() async throws {
        let fixture = Fixture()
        var captures = 0
        fixture.controller.startCaptureAudio = { captures += 1 }
        fixture.client.onStart = { fixture.client.failure?(Failure()) }
        do {
            try await fixture.controller.start()
            XCTFail("Immediate provider failure must fail startup")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(fixture.client.cancellations, 1)
        fixture.updates.deliverAll()
        fixture.client.onStart = nil
        try await fixture.controller.start()
        await fixture.controller.stop()
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testWatchdogForwardsDeclaredClientBudgetWithoutShorteningDefault() async throws {
        let fixture = Fixture()
        fixture.client.finalisationBudget = 20
        try await fixture.controller.start()
        XCTAssertEqual(fixture.controller.stopCompletionTimeout, 21)
        await fixture.controller.stop()
        fixture.client.finalisationBudget = 5
        try await fixture.controller.start()
        XCTAssertEqual(fixture.controller.stopCompletionTimeout, 10)
        await fixture.controller.stop()
    }

    func testRunKeepsRevisedConfirmationSeparateFromFailedVisibleDraft() {
        let run = SharedClientControllerRun(shape: .cumulativeTranscript, modelIdentifier: "test")
        _ = run.receive("Hello", isFinal: true)
        _ = run.receive("Hello trailing words", isFinal: false)
        _ = run.fail(Failure())
        let snapshot = run.finish(whole: "Hello, revised.", cancelled: false)
        XCTAssertEqual(snapshot.text, "Hello trailing words")
        XCTAssertEqual(snapshot.confirmedText, "Hello, revised.")
        XCTAssertFalse(snapshot.isFinal)
    }
}

@MainActor
private extension SharedClientLiveControllerRecoveryTests {
    struct Failure: Error {}

    final class Client: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
        var finalShape: TranscriptFinalShape = .cumulativeTranscript
        var finalisationBudget: TimeInterval?
        var onStart: (() -> Void)?
        var abort: (() -> Void)?
        var transcript: ((String, Bool) -> Void)?
        var failure: ((Error) -> Void)?
        var finish: (@MainActor () async -> String?)?
        var cancellations = 0
        func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
            transcript = onTranscript
            failure = onError
            onStart?()
        }
        func sendAudio(_ data: Data) {}
        func stop() { cancellations += 1; abort?() }
        func finishAndWait() async -> String? { await finish?() }
    }

    final class Delegate: LiveTranscriptionSessionDelegate {
        var partials: [String] = []
        var errors: [Error] = []
        var results: [TranscriptionResult] = []
        var boundaries: [String] = []
        var onPartial: (() -> Void)?
        func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String) {
            partials.append(text)
            onPartial?()
        }
        func liveTranscriber(_ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult) {
            results.append(result)
        }
        func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error) { errors.append(error) }
        func liveTranscriber(
            _ session: any LiveTranscriptionController, didUpdateWith update: LiveTranscriptionUpdate
        ) {}
        func liveTranscriber(_ session: any LiveTranscriptionController, didDetectUtteranceBoundary text: String) {
            boundaries.append(text)
        }
    }

    final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [@MainActor @Sendable () -> Void] = []
        nonisolated func enqueue(_ update: @escaping @MainActor @Sendable () -> Void) {
            lock.withLock { queued.append(update) }
        }
        @MainActor func deliverAll() {
            let updates = lock.withLock { let value = queued; queued.removeAll(); return value }
            for update in updates { update() }
        }
    }

    @MainActor final class Fixture {
        let client = Client()
        let delegate = Delegate()
        let updates = Updates()
        let controller: SharedClientLiveController
        init() {
            let settings = AppSettings()
            let permissions = PermissionsManager()
            let audioDevices = AudioInputDeviceManager(appSettings: settings)
            let storage = SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.shared-recovery.\(UUID().uuidString)"
            )
            controller = SharedClientLiveController(
                permissionsManager: permissions, audioDeviceManager: audioDevices,
                secureStorage: storage, appSettings: settings
            )
            controller.configure(language: nil, model: XAISpeechToText.liveCatalogID)
            controller.clientFactory = { [client] in client }
            controller.startCaptureAudio = {}
            controller.enqueueClientUpdate = { [updates] in updates.enqueue($0) }
            controller.delegate = delegate
        }
    }
}
