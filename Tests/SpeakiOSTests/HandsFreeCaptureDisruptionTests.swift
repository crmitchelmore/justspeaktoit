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
        await settle()
        XCTAssertEqual(coordinator.state, .armed)
        for reason: AVAudioSession.RouteChangeReason in [.newDeviceAvailable, .oldDeviceUnavailable,
                                                       .categoryChange, .override] {
            await coordinator.handleRouteChange(reason: reason)
            XCTAssertEqual(coordinator.state, .armed)
            XCTAssertNil(coordinator.failureMessage)
        }
        coordinator.detectorIsRunning = { false }
        await coordinator.handleRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(coordinator.state, .off)
        XCTAssertEqual(coordinator.failureMessage, "The microphone changed and recording stopped.")
    }

    func testLostInput_disarmsAndLaterArmClearsNotice() async {
        let coordinator = makeCoordinator()
        await coordinator.toggle()
        await settle()
        coordinator.inputIsUsable = { false }
        await coordinator.handleRouteChange(reason: .unknown)
        XCTAssertEqual(coordinator.state, .off)
        coordinator.inputIsUsable = { true }
        await coordinator.toggle()
        await settle()
        XCTAssertEqual(coordinator.state, .armed)
        XCTAssertNil(coordinator.failureMessage)
        await coordinator.disarm()
    }

    func testActiveUtterance_duplicateDisruptionAndDisarmPreserveOneFinalisation() async {
        var finishes = 0
        var finish: CheckedContinuation<HandsFreeCaptureEndOutcome, Never>?
        let finishing = expectation(description: "utterance finishing")
        let coordinator = makeCoordinator(stopCapture: {
            finishes += 1
            return await withCheckedContinuation { continuation in
                finish = continuation
                finishing.fulfill()
            }
        })
        await coordinator.toggle()
        await settle()
        await coordinator.handleActivity(AppleSpeechActivityUpdate(speechDetected: true, seconds: 1))
        XCTAssertEqual(coordinator.state, .recording)
        await coordinator.stopForCaptureDisruption()
        await fulfillment(of: [finishing], timeout: 2)
        await coordinator.stopForCaptureDisruption()
        await coordinator.disarm()
        XCTAssertEqual(coordinator.state, .finalising)
        XCTAssertEqual(finishes, 1)
        finish?.resume(returning: .completed)
        await settle()
        XCTAssertEqual(coordinator.state, .off)
        XCTAssertEqual(coordinator.failureMessage, "The microphone changed and recording stopped.")
    }

    private func makeCoordinator(
        stopCapture: @escaping IOSHandsFreeDictationCoordinator.StopCapture = { .completed }
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

    private func settle() async {
        await Task { @MainActor in }.value
    }
}
#endif
