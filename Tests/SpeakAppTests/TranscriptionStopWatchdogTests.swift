import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class TranscriptionStopWatchdogTests: XCTestCase {
    func testElevenLabsWholeStopOutlivesDrainAndTheExactBoundedGrace() {
        for grace in [0.0, 0.1, 1, 2, -1, 500, .infinity, .nan] {
            let bounded = ElevenLabsStopPolicy.boundedGrace(grace)
            XCTAssertTrue((0...2).contains(bounded))
            XCTAssertGreaterThan(
                ElevenLabsStopPolicy.completionTimeout(grace: grace),
                ElevenLabsLiveClient.finishDrainBudget + bounded
            )
        }
        XCTAssertEqual(ElevenLabsStopPolicy.completionTimeout(grace: 2), 13)
        XCTAssertEqual(DefaultController().stopCompletionTimeout, 10, "Other controllers retain their existing bound")
    }

    func testFinalAfterOldTenSecondLimitUsesTheCapturedProviderBudget() async throws {
        let harness = makeHarness()
        let manager = harness.manager
        let controller = harness.controller
        let clock = harness.clock
        try await manager.startLiveTranscription()
        let waiting = expectation(description: "watchdog scheduled")
        waiting.expectedFulfillmentCount = 2
        clock.onWait = { waiting.fulfill() }
        controller.onStop = { waiting.fulfill() }
        let stopping = Task { try await manager.stopLiveTranscription() }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(clock.durations, [13])
        controller.stopCompletionTimeout = 1
        clock.advance(by: 11)
        await Task.yield()
        XCTAssertTrue(manager.isLiveTranscribing, "Changing configuration must not shorten an in-flight run")
        controller.finish("authoritative trailing words")
        let result = try await stopping.value
        XCTAssertEqual(result.text, "authoritative trailing words")
        clock.advance(by: 10)
    }

    func testSpecificProviderFailureAfterOldTenSecondLimitIsPreserved() async throws {
        let harness = makeHarness()
        let manager = harness.manager
        let controller = harness.controller
        let clock = harness.clock
        try await manager.startLiveTranscription()
        let waiting = expectation(description: "watchdog scheduled")
        waiting.expectedFulfillmentCount = 2
        clock.onWait = { waiting.fulfill() }
        controller.onStop = { waiting.fulfill() }
        let stopping = Task { try await manager.stopLiveTranscription() }
        await fulfillment(of: [waiting], timeout: 2)
        clock.advance(by: 11)
        await Task.yield()
        controller.fail()
        do {
            _ = try await stopping.value
            XCTFail("A failed provider must not become success")
        } catch {
            XCTAssertTrue(error is ProviderFailure)
        }
        clock.advance(by: 10)
    }

    func testFastFinalCancelsItsWatchdogAndLateWakeCannotFailReplacement() async throws {
        try await verifyRetiredWatchdogDoesNotAffectReplacement(cancelFirst: false)
    }

    func testCancellationRetiresWatchdogAndLateWakeCannotFailReplacement() async throws {
        try await verifyRetiredWatchdogDoesNotAffectReplacement(cancelFirst: true)
    }
}

@MainActor
private extension TranscriptionStopWatchdogTests {
    struct ProviderFailure: Error {}

    final class DefaultController: LiveTranscriptionController {
        weak var delegate: LiveTranscriptionSessionDelegate?
        var isRunning = false
        func configure(language: String?, model: String) {}
        func start() async throws {}
        func stop() async {}
    }

    final class Controller: LiveTranscriptionController {
        weak var delegate: LiveTranscriptionSessionDelegate?
        var isRunning = false
        var stopCompletionTimeout = ElevenLabsStopPolicy.completionTimeout(grace: 2)
        var onStop: (() -> Void)?
        private var stopContinuation: CheckedContinuation<Void, Never>?
        func configure(language: String?, model: String) {}
        func start() async throws { isRunning = true }
        func stop() async {
            await withCheckedContinuation {
                stopContinuation = $0
                onStop?()
            }
            isRunning = false
        }
        func finish(_ text: String) {
            delegate?.liveTranscriber(self, didFinishWith: TranscriptionResult(
                text: text, segments: [], confidence: nil, duration: 1,
                modelIdentifier: "elevenlabs/scribe-v2-streaming", cost: nil, rawPayload: nil, debugInfo: nil
            ))
            release()
        }
        func fail() {
            delegate?.liveTranscriber(self, didFail: ProviderFailure())
            release()
        }
        func release() { stopContinuation?.resume(); stopContinuation = nil }
    }

    /// Deliberately completes cancelled sleepers too, exercising the manager's
    /// cancellation and generation guards rather than relying on timer disposal.
    final class Clock {
        var onWait: (() -> Void)?
        var durations: [TimeInterval] = []
        private var now: TimeInterval = 0
        private var pending: [(deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
        func sleep(_ duration: TimeInterval) async {
            await withCheckedContinuation {
                durations.append(duration)
                pending.append((now + duration, $0))
                onWait?()
            }
        }
        func advance(by duration: TimeInterval) {
            now += duration
            let ready = pending.filter { $0.deadline <= now }
            pending.removeAll { $0.deadline <= now }
            for entry in ready { entry.continuation.resume() }
        }
    }

    func verifyRetiredWatchdogDoesNotAffectReplacement(cancelFirst: Bool) async throws {
        let harness = makeHarness()
        let manager = harness.manager
        let controller = harness.controller
        let clock = harness.clock
        try await manager.startLiveTranscription()
        let firstWaiting = expectation(description: "first watchdog scheduled")
        firstWaiting.expectedFulfillmentCount = 2
        clock.onWait = { firstWaiting.fulfill() }
        controller.onStop = { firstWaiting.fulfill() }
        let firstStop = Task { try await manager.stopLiveTranscription() }
        await fulfillment(of: [firstWaiting], timeout: 2)
        if cancelFirst {
            manager.cancelLiveTranscription()
            controller.release()
            do {
                _ = try await firstStop.value
                XCTFail("Cancelled stop must throw")
            } catch {
                XCTAssertEqual(error as? TranscriptionManagerError, .liveSessionNotRunning)
            }
        } else {
            controller.finish("first")
            let first = try await firstStop.value
            XCTAssertEqual(first.text, "first")
        }
        await manager.liveController.stop()
        clock.advance(by: 10)
        try await manager.startLiveTranscription()
        let secondWaiting = expectation(description: "replacement watchdog scheduled")
        secondWaiting.expectedFulfillmentCount = 2
        clock.onWait = { secondWaiting.fulfill() }
        controller.onStop = { secondWaiting.fulfill() }
        let secondStop = Task { try await manager.stopLiveTranscription() }
        await fulfillment(of: [secondWaiting], timeout: 2)
        clock.advance(by: 4)
        await Task.yield()
        XCTAssertTrue(manager.isLiveTranscribing, "The retired watchdog cannot consume the replacement continuation")
        controller.finish("replacement")
        let second = try await secondStop.value
        XCTAssertEqual(second.text, "replacement")
        clock.advance(by: 20)
    }

    struct Harness {
        let manager: TranscriptionManager
        let controller: Controller
        let clock: Clock
    }

    func makeHarness() -> Harness {
        let suite = "com.justspeaktoit.tests.stop-watchdog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionMode = .liveNative
        settings.liveTranscriptionModel = "elevenlabs/scribe-v2-streaming"
        let permissions = PermissionsManager()
        let audioDevices = AudioInputDeviceManager(appSettings: settings)
        let secureStorage = SecureAppStorage(
            permissionsManager: permissions, appSettings: settings, keychainService: suite
        )
        let openRouter = OpenRouterAPIClient(secureStorage: secureStorage)
        let controller = Controller()
        let clock = Clock()
        let manager = TranscriptionManager(
            appSettings: settings, permissionsManager: permissions, audioDeviceManager: audioDevices,
            batchClient: RemoteAudioTranscriber(client: openRouter), openRouter: openRouter,
            secureStorage: secureStorage, controllerOverride: { _ in controller },
            stopTimeoutSleep: { await clock.sleep($0) }
        )
        return Harness(manager: manager, controller: controller, clock: clock)
    }
}
