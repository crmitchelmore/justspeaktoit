#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class HandsFreeCaptureDisruptionTests: XCTestCase {
    func testHarmlessRoutes_remainArmedButStoppedDetectorDisarms() async throws {
        let coordinator = makeCoordinator()
        await coordinator.toggle()
        await settle(coordinator, until: "the detector to arm") { coordinator.state == .armed }
        XCTAssertEqual(coordinator.state, .armed)
        for reason: AVAudioSession.RouteChangeReason in [.newDeviceAvailable, .oldDeviceUnavailable,
                                                       .categoryChange, .override] {
            await coordinator.handleRouteChange(reason: reason)
            XCTAssertEqual(coordinator.state, .armed)
            XCTAssertNil(coordinator.failureMessage)
        }
        coordinator.detectorIsRunning = { false }
        await coordinator.handleRouteChange(reason: .oldDeviceUnavailable)
        await settle(coordinator, until: "the lost detector to disarm with its failure") {
            coordinator.state == .off && coordinator.failureMessage != nil
        }
        XCTAssertEqual(coordinator.state, .off)
        XCTAssertEqual(coordinator.failureMessage, "The microphone changed and recording stopped.")
    }

    func testLostInput_disarmsAndLaterArmClearsNotice() async {
        let coordinator = makeCoordinator()
        await coordinator.toggle()
        await settle(coordinator, until: "the detector to arm") { coordinator.state == .armed }
        coordinator.inputIsUsable = { false }
        await coordinator.handleRouteChange(reason: .unknown)
        await settle(coordinator, until: "the lost input to disarm") { coordinator.state == .off }
        XCTAssertEqual(coordinator.state, .off)
        coordinator.inputIsUsable = { true }
        await coordinator.toggle()
        await settle(coordinator, until: "the detector to re-arm") { coordinator.state == .armed }
        XCTAssertEqual(coordinator.state, .armed)
        XCTAssertNil(coordinator.failureMessage)
        await coordinator.disarm()
    }

    func testActiveUtterance_duplicateDisruptionAndDisarmPreserveOneFinalisation() async {
        var finishes = 0
        var finish: CheckedContinuation<HandsFreeCaptureEndOutcome, Never>?
        let finishing = expectation(description: "utterance finishing")
        let coordinator = makeCoordinator(stopCapture: { _ in
            finishes += 1
            return await withCheckedContinuation { continuation in
                finish = continuation
                finishing.fulfill()
            }
        })
        await coordinator.toggle()
        await settle(coordinator, until: "the detector to arm") { coordinator.state == .armed }
        await coordinator.handleActivity(AppleSpeechActivityUpdate(speechDetected: true, seconds: 1))
        XCTAssertEqual(coordinator.state, .recording)
        await coordinator.stopForCaptureDisruption()
        await fulfillment(of: [finishing], timeout: 2)
        await coordinator.stopForCaptureDisruption()
        await coordinator.disarm()
        XCTAssertEqual(coordinator.state, .finalising)
        XCTAssertEqual(finishes, 1)
        finish?.resume(returning: .completed)
        await settle(coordinator, until: "the finalised utterance to disarm with its disruption notice") {
            coordinator.state == .off && coordinator.failureMessage != nil
        }
        XCTAssertEqual(coordinator.state, .off)
        XCTAssertEqual(coordinator.failureMessage, "The microphone changed and recording stopped.")
        XCTAssertEqual(finishes, 1)
    }

    func testInterruption_armedSessionDisarmsWithoutErrorAndDoesNotResume() async {
        let coordinator = makeCoordinator()
        await coordinator.toggle()
        await settle(coordinator, until: "the detector to arm") { coordinator.state == .armed }
        InterruptionSession.post(.began)
        InterruptionSession.post(.ended)
        await settle(coordinator, until: "the interruption to disarm with its stop notice") {
            coordinator.state == .off && coordinator.captureStopNotice != nil
        }
        XCTAssertEqual(coordinator.state, .off)
        XCTAssertNil(coordinator.failureMessage)
        XCTAssertEqual(coordinator.captureStopNotice, iOSTranscriptionError.interrupted.localizedDescription)
        InterruptionSession.post(.ended)
        await drainPendingWork()
        XCTAssertEqual(coordinator.state, .off)
    }

    func testInterruption_activeUtteranceDrainsBeforeDisarmAndKeepsRealFailure() async {
        for failure in [false, true] {
            var finishes = 0
            var finish: CheckedContinuation<HandsFreeCaptureEndOutcome, Never>?
            let draining = expectation(description: "utterance drain")
            let coordinator = makeCoordinator(stopCapture: { _ in
                finishes += 1
                return await withCheckedContinuation {
                    finish = $0
                    draining.fulfill()
                }
            })
            await coordinator.toggle()
            await settle(coordinator, until: "the detector to arm") { coordinator.state == .armed }
            await coordinator.handleActivity(AppleSpeechActivityUpdate(speechDetected: true, seconds: 1))
            InterruptionSession.post(.began)
            await fulfillment(of: [draining], timeout: 2)
            InterruptionSession.post(.began)
            InterruptionSession.post(.ended)
            await coordinator.stopForCaptureDisruption()
            XCTAssertEqual(coordinator.state, .finalising)
            XCTAssertEqual(finishes, 1)
            finish?.resume(returning: failure ? .failed(.captureFailed) : .completed)
            await settle(coordinator, until: "the drained utterance to disarm") {
                coordinator.state == .off
                    && (failure ? coordinator.failureMessage != nil : coordinator.captureStopNotice != nil)
            }
            XCTAssertEqual(coordinator.state, .off)
            if failure {
                XCTAssertNotNil(coordinator.failureMessage)
            } else {
                XCTAssertNil(coordinator.failureMessage)
                XCTAssertEqual(coordinator.captureStopNotice, iOSTranscriptionError.interrupted.localizedDescription)
            }
        }
    }

    private func makeCoordinator(
        stopCapture: @escaping IOSHandsFreeDictationCoordinator.StopCapture = { _ in .completed }
    ) -> IOSHandsFreeDictationCoordinator {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let coordinator = IOSHandsFreeDictationCoordinator(
            audioSessionManager: manager,
            startCapture: { _ in .started },
            stopCapture: stopCapture,
            cancelCapture: { XCTFail("Disruption must not cancel a capture") },
            silenceDuration: { 2 },
            captureIsSupported: { true },
            liveActivitiesEnabled: { false }
        )
        coordinator.startDetectorCapture = {}
        coordinator.detectorIsRunning = { true }
        coordinator.inputIsUsable = { true }
        return coordinator
    }

    private static let settleTimeout: Duration = .seconds(5)

    /// Waits for the coordinator to reach a settled condition. Arming and
    /// finalisation each cross several async hops — the stop owner's
    /// continuation, the machine transition, then the published notice — so a
    /// fixed number of main-actor hops observes them mid-flight whenever the
    /// runner is loaded. Timing out fails loudly and names what was observed.
    private func settle(
        _ coordinator: IOSHandsFreeDictationCoordinator,
        until description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        isSettled: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + Self.settleTimeout
        while !isSettled() {
            guard ContinuousClock.now < deadline else {
                XCTFail(
                    "Timed out after \(Self.settleTimeout) waiting for \(description). "
                        + "Observed state=\(coordinator.state), "
                        + "failureMessage=\(String(describing: coordinator.failureMessage)), "
                        + "captureStopNotice=\(String(describing: coordinator.captureStopNotice))",
                    file: file,
                    line: line
                )
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Lets any pending main-actor work run where the test asserts that
    /// *nothing* further happens, so the absence is observed, not assumed.
    private func drainPendingWork() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
#endif
