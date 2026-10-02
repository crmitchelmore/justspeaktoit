#if os(iOS)
import AVFoundation
import Combine
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class HandsFreeSceneLifecycleTests: XCTestCase {
    func testInactiveThenBackground_finishesOnceAndRequiresExplicitRearm() async {
        let harness = Harness()
        await harness.record()
        let finishing = harness.holdFinalisation()
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        await fulfillment(of: [finishing], timeout: 2)
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        await harness.coordinator.finishCurrentUtterance()
        await harness.coordinator.stopForCaptureDisruption()
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await Task { @MainActor in }.value
        await harness.coordinator.disarm()
        await harness.coordinator.handleActivity(.init(speechDetected: true, seconds: 10))
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.starts, 1)
        XCTAssertEqual(harness.coordinator.state, .finalising)
        harness.finish?.resume(returning: .completed)
        await waitForState(.off, harness.coordinator)
        XCTAssertEqual(harness.savedText, "Recognisable captured words")
        XCTAssertEqual(harness.history, ["Recognisable captured words"])
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.rearmAtCompletion, false)
        XCTAssertEqual(harness.resumes, 0)
        XCTAssertNil(harness.coordinator.failureMessage)
        await harness.coordinator.toggle()
        XCTAssertEqual(harness.coordinator.state, .off)
        harness.coordinator.sceneActivityChanged(isActive: true)
        XCTAssertEqual(harness.coordinator.state, .off)
        await harness.arm()
        XCTAssertEqual(harness.starts, 1)
        await harness.coordinator.disarm()
    }

    func testInactiveWhileAlreadyFinishing_revokesRearmWithoutCancellingResult() async {
        let harness = Harness()
        await harness.record()
        let finishing = harness.holdFinalisation()
        await harness.coordinator.finishCurrentUtterance()
        await fulfillment(of: [finishing], timeout: 2)
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        harness.coordinator.sceneActivityChanged(isActive: true)
        // A tap while finalising cannot arm another microphone owner.
        await harness.coordinator.toggle()
        XCTAssertEqual(harness.coordinator.state, .finalising)
        harness.finish?.resume(returning: .completed)
        await waitForState(.off, harness.coordinator)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.history.count, 1)
        XCTAssertEqual(harness.rearmAtCompletion, false)
        XCTAssertEqual(harness.resumes, 0)
        XCTAssertEqual(harness.configurations, 1)
    }

    func testInactiveDuringDetectorResume_doesNotRestartAfterConfigurationReturns() async {
        let harness = Harness()
        await harness.record()
        let configuring = expectation(description: "resume configuration")
        var resume: CheckedContinuation<Void, Never>?
        harness.manager.configureRecording = {
            await withCheckedContinuation { continuation in
                resume = continuation
                configuring.fulfill()
            }
        }
        await harness.coordinator.finishCurrentUtterance()
        await fulfillment(of: [configuring], timeout: 2)
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        resume?.resume()
        await waitForState(.off, harness.coordinator)
        XCTAssertEqual(harness.resumes, 0)
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.history.count, 1)
        XCTAssertNil(harness.coordinator.failureMessage)
    }

    func testDelayedArmingCompletion_doesNotStopNewExplicitSession() async {
        await assertRetiredArmDoesNotAffectNewSession(throwsError: false)
    }

    func testDelayedArmingFailure_doesNotFailNewExplicitSession() async {
        await assertRetiredArmDoesNotAffectNewSession(throwsError: true)
    }

    func testLateAudioConfigurationAfterInactivity_releasesRetiredActivation() async {
        await assertLateConfiguration(rearm: false)
    }

    func testLateAudioConfigurationAfterNewArm_doesNotDeactivateNewSession() async {
        await assertLateConfiguration(rearm: true)
    }

    private func assertLateConfiguration(rearm: Bool) async {
        let harness = Harness()
        let configuring = expectation(description: "audio configuration suspended")
        let returned = expectation(description: "late audio configuration returned")
        var configured: CheckedContinuation<Void, Never>?
        harness.manager.configureRecording = {
            await withCheckedContinuation { continuation in
                configured = continuation
                configuring.fulfill()
            }
            returned.fulfill()
        }
        let retiredStart = await harness.beginArming()
        await fulfillment(of: [configuring], timeout: 2)
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        let deactivations = harness.deactivations
        if rearm {
            harness.coordinator.sceneActivityChanged(isActive: true)
            harness.manager.configureRecording = {}
            await harness.arm()
        }
        configured?.resume()
        await retiredStart?.value
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(harness.deactivations, deactivations + (rearm ? 0 : 1))
        XCTAssertEqual(harness.coordinator.state, rearm ? .armed : .off)
        XCTAssertNil(harness.coordinator.failureMessage)
        if rearm { await harness.coordinator.disarm() }
    }

    func testInactiveDuringCaptureStartup_finishesOnceAfterOwnedStartSettles() async {
        let harness = Harness()
        let starting = expectation(description: "capture starting")
        var started: CheckedContinuation<HandsFreeCaptureStartOutcome, Never>?
        harness.startCapture = {
            await withCheckedContinuation { continuation in
                started = continuation
                starting.fulfill()
            }
        }
        await harness.arm()
        let capture = Task { await harness.coordinator.handleActivity(.init(speechDetected: true, seconds: 1)) }
        await fulfillment(of: [starting], timeout: 2)
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        await harness.coordinator.finishCurrentUtterance()
        await harness.coordinator.disarm()
        XCTAssertEqual(harness.stops, 0)
        started?.resume(returning: .started)
        await capture.value
        await waitForState(.off, harness.coordinator)
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.history.count, 1)
    }

    func testInactiveOffAndArmed_neverFinishOrCancelAnotherCapture() async {
        let harness = Harness()
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        XCTAssertEqual(harness.deactivations, 0)
        harness.coordinator.sceneActivityChanged(isActive: true)
        await harness.arm()
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        XCTAssertEqual(harness.coordinator.state, .off)
        XCTAssertEqual(harness.stops, 0)
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.deactivations, 1)
        XCTAssertTrue(harness.history.isEmpty)
        XCTAssertNil(harness.coordinator.failureMessage)
    }

    func testSceneStopFailure_retainsAvailableContentAndReportsActualFailure() async {
        let harness = Harness()
        await harness.record()
        let finishing = harness.holdFinalisation()
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        await fulfillment(of: [finishing], timeout: 2)
        harness.finish?.resume(returning: .failed(.captureFailed))
        await waitForState(.off, harness.coordinator)
        XCTAssertEqual(harness.savedText, "Recognisable captured words")
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.coordinator.failureMessage, HandsFreeDictationMachine.Failure.captureFailed.message)
    }

    func testEmptySceneStop_doesNotFabricateText() async {
        let harness = Harness()
        harness.savedText = ""
        await harness.record()
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        await waitForState(.off, harness.coordinator)
        XCTAssertEqual(harness.savedText, "")
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertNil(harness.coordinator.failureMessage)
    }

    func testExplicitDisarm_stillCancelsOwnedCapture() async {
        let harness = Harness()
        await harness.record()
        await harness.coordinator.disarm()
        XCTAssertEqual(harness.cancels, 1)
        XCTAssertEqual(harness.stops, 0)
        XCTAssertEqual(harness.savedText, "")
    }

    func testOrdinaryForegroundStop_stillRearmsDetector() async {
        let harness = Harness()
        await harness.record()
        await harness.coordinator.finishCurrentUtterance()
        await waitForState(.armed, harness.coordinator)
        XCTAssertEqual(harness.rearmAtCompletion, true)
        XCTAssertEqual(harness.resumes, 1)
        XCTAssertEqual(harness.cancels, 0)
        await harness.coordinator.disarm()
    }

    func testCancelledFinalisation_lateFailureCannotDisarmNewRecording() async {
        let harness = Harness()
        await harness.record()
        let finishing = harness.holdFinalisation()
        await harness.coordinator.finishCurrentUtterance()
        let retiredFinalisation = harness.coordinator.finalisationTask
        await fulfillment(of: [finishing], timeout: 2)
        await harness.coordinator.disarm()
        await harness.record()
        // Wait for the retired stop to hand its late failure back. A single
        // main-actor hop can run before the resumed continuation does, which
        // asserted before the failure arrived and let the test release the
        // harness while that stop was still pending.
        let returned = harness.expectStopReturn()
        harness.finish?.resume(returning: .failed(.captureFailed))
        await retiredFinalisation?.value
        // The retired owner did reach its rearm decision, and was refused.
        XCTAssertEqual(harness.rearmAtCompletion, false)
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(harness.coordinator.state, .recording)
        XCTAssertNil(harness.coordinator.failureMessage)
        XCTAssertEqual(harness.cancels, 1)
        XCTAssertEqual(harness.resumes, 0)
        await harness.coordinator.disarm()
    }

    private func assertRetiredArmDoesNotAffectNewSession(throwsError: Bool) async {
        let harness = Harness()
        let preparing = expectation(description: "detector preparing")
        let returned = expectation(description: "retired detector start returned")
        var prepared: CheckedContinuation<Void, Error>?
        harness.coordinator.startDetectorCapture = {
            defer { returned.fulfill() }
            try await withCheckedThrowingContinuation { continuation in
                prepared = continuation
                preparing.fulfill()
            }
        }
        let retiredStart = await harness.beginArming()
        await fulfillment(of: [preparing], timeout: 2)
        await harness.coordinator.sceneActivityChanged(isActive: false)?.value
        XCTAssertEqual(harness.coordinator.state, .off)
        harness.coordinator.sceneActivityChanged(isActive: true)
        harness.coordinator.startDetectorCapture = {}
        await harness.arm()
        let deactivations = harness.deactivations
        if throwsError {
            prepared?.resume(throwing: NSError(domain: "RetiredDetector", code: 1))
        } else {
            prepared?.resume()
        }
        await retiredStart?.value
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(harness.coordinator.state, .armed)
        XCTAssertEqual(harness.deactivations, deactivations)
        XCTAssertNil(harness.coordinator.failureMessage)
        await harness.coordinator.disarm()
    }

    private func waitForState(_ state: HandsFreeDictationMachine.State,
                              _ coordinator: IOSHandsFreeDictationCoordinator) async {
        let reached = expectation(description: "state \(state)")
        let observer = coordinator.$state.first { $0 == state }.sink { _ in reached.fulfill() }
        await fulfillment(of: [reached], timeout: 2)
        withExtendedLifetime(observer) {}
    }
}

// Boundaries capture the fixture unowned on purpose. A call after a test has
// released it means the test returned without joining work it started; that
// must fail loudly rather than be absorbed by a weak capture.
@MainActor
private final class Harness {
    let manager = AudioSessionManager()
    var starts = 0
    var stops = 0
    var cancels = 0
    var resumes = 0
    var configurations = 0
    var deactivations = 0
    var savedText = "Recognisable captured words"
    var history: [String] = []
    var rearmAtCompletion: Bool?
    var finish: CheckedContinuation<HandsFreeCaptureEndOutcome, Never>?
    var finishing: XCTestExpectation?
    var stopReturned: XCTestExpectation?
    var startCapture: (() async -> HandsFreeCaptureStartOutcome)?
    // The coordinator and its tasks can outlive this harness: a retired
    // finalisation resumes whenever its continuation is scheduled. Callbacks
    // capture the harness weakly, so a call in flight keeps it alive until it
    // returns and a call that starts after the test released it does nothing.
    lazy var coordinator = IOSHandsFreeDictationCoordinator(
        audioSessionManager: manager,
        startCapture: { [weak self] _ in
            guard let self else { return .rejected(.captureFailed) }
            self.starts += 1
            return await self.startCapture?() ?? .started
        },
        stopCapture: { [weak self] shouldRearm in
            guard let self else { return .failed(.captureFailed) }
            self.stops += 1
            let outcome: HandsFreeCaptureEndOutcome
            if let finishing = self.finishing {
                outcome = await withCheckedContinuation { continuation in
                    self.finish = continuation
                    finishing.fulfill()
                }
            } else { outcome = .completed }
            self.rearmAtCompletion = shouldRearm()
            self.history.append(self.savedText)
            self.stopReturned?.fulfill()
            return outcome
        },
        cancelCapture: { [weak self] in
            self?.cancels += 1
            self?.savedText = ""
        },
        silenceDuration: { 2 },
        captureIsSupported: { true },
        liveActivitiesEnabled: { false }
    )

    init() {
        manager.permissionStatus = { true }
        manager.configureRecording = { [weak self] in self?.configurations += 1 }
        manager.deactivateRecording = { [weak self] in self?.deactivations += 1 }
        coordinator.startDetectorCapture = {}
        coordinator.resumeDetectorCapture = { [weak self] in self?.resumes += 1 }
        coordinator.detectorIsRunning = { true }
        coordinator.inputIsUsable = { true }
    }

    /// Toggles arming on and returns its detector start. Retirement drops the
    /// coordinator's reference, so a test keeps this one to join that exact
    /// operation: a resumed boundary returns through the global executor, which
    /// no fixed number of main-actor turns is guaranteed to wait for.
    func beginArming() async -> Task<Void, Never>? {
        await coordinator.toggle()
        XCTAssertNotNil(coordinator.armTask, "Arming must own a detector start")
        return coordinator.armTask
    }

    func arm() async {
        await beginArming()?.value
        XCTAssertEqual(coordinator.state, .armed)
    }

    func record() async {
        await arm()
        await coordinator.handleActivity(.init(speechDetected: true, seconds: 1))
        XCTAssertEqual(coordinator.state, .recording)
    }

    func holdFinalisation() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "capture finalising")
        finishing = expectation
        return expectation
    }

    /// Fulfilled when a stop hands its outcome back to the coordinator, so a
    /// test can wait for a late result instead of guessing how many hops it takes.
    func expectStopReturn() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "capture stop returned")
        stopReturned = expectation
        return expectation
    }
}
#endif
