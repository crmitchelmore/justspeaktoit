import Foundation
import XCTest
@testable import SpeakCore

final class CaptureWarmStateMachineTests: XCTestCase {
    private func context(
        device: String? = "built-in-mic",
        directory: String = "/Users/test/Recordings",
        encoder: String = "aac-44100-mono-128k",
        requiresSwitch: Bool = false,
        permissionGranted: Bool = true
    ) -> CaptureWarmContext {
        CaptureWarmContext(
            inputDeviceUID: device,
            recordingsDirectoryPath: directory,
            encoderProfileID: encoder,
            requiresDefaultDeviceSwitch: requiresSwitch,
            microphonePermissionGranted: permissionGranted
        )
    }

    // MARK: - Eligibility

    func testWarmable_RequiresPermissionDeviceAndNoDefaultSwitch() {
        XCTAssertTrue(self.context().isWarmable)
        XCTAssertFalse(self.context(permissionGranted: false).isWarmable)
        XCTAssertFalse(self.context(requiresSwitch: true).isWarmable)
        XCTAssertFalse(self.context(device: nil).isWarmable)
        XCTAssertFalse(self.context(directory: "").isWarmable)
    }

    // MARK: - Happy path

    func testReconcile_StagesThenClaims() {
        var machine = CaptureWarmStateMachine()
        let context = self.context()

        XCTAssertEqual(machine.reconcile(with: context, enabled: true), .prepare(context))
        XCTAssertNil(machine.readyContext)

        XCTAssertTrue(machine.markReady(context))
        XCTAssertEqual(machine.readyContext, context)

        XCTAssertTrue(machine.claim(for: context))
        XCTAssertEqual(machine.phase, .cold)
        XCTAssertNil(machine.readyContext)
    }

    func testReconcile_IsIdempotentWhileStagedForSameEnvironment() {
        var machine = CaptureWarmStateMachine()
        let context = self.context()

        _ = machine.reconcile(with: context, enabled: true)
        XCTAssertEqual(machine.reconcile(with: context, enabled: true), .none)

        machine.markReady(context)
        XCTAssertEqual(machine.reconcile(with: context, enabled: true), .none)
    }

    // MARK: - Rewarm triggers

    func testRouteChange_RestagesForTheNewDevice() {
        var machine = CaptureWarmStateMachine()
        let original = self.context(device: "built-in-mic")
        _ = machine.reconcile(with: original, enabled: true)
        machine.markReady(original)

        let rerouted = self.context(device: "usb-mic")
        XCTAssertEqual(
            machine.reconcile(with: rerouted, enabled: true),
            .discardThenPrepare(rerouted)
        )
        XCTAssertNil(machine.readyContext)
        machine.markReady(rerouted)
        XCTAssertEqual(machine.readyContext, rerouted)
    }

    func testRecordingsDirectoryChange_Restages() {
        var machine = CaptureWarmStateMachine()
        let original = self.context()
        _ = machine.reconcile(with: original, enabled: true)
        machine.markReady(original)

        let moved = self.context(directory: "/Users/test/Elsewhere")
        XCTAssertEqual(machine.reconcile(with: moved, enabled: true), .discardThenPrepare(moved))
    }

    func testEncoderProfileChange_Restages() {
        var machine = CaptureWarmStateMachine()
        let original = self.context()
        _ = machine.reconcile(with: original, enabled: true)
        machine.markReady(original)

        let reencoded = self.context(encoder: "aac-16000-mono-64k")
        XCTAssertEqual(machine.reconcile(with: reencoded, enabled: true), .discardThenPrepare(reencoded))
    }

    func testRouteChangeWhileStaging_RestagesWithoutAcceptingTheStaleResult() {
        var machine = CaptureWarmStateMachine()
        let original = self.context(device: "built-in-mic")
        _ = machine.reconcile(with: original, enabled: true)

        let rerouted = self.context(device: "usb-mic")
        XCTAssertEqual(
            machine.reconcile(with: rerouted, enabled: true),
            .discardThenPrepare(rerouted)
        )

        // The in-flight staging for the old device finishes late and is rejected.
        XCTAssertFalse(machine.markReady(original))
        XCTAssertNil(machine.readyContext)

        XCTAssertTrue(machine.markReady(rerouted))
        XCTAssertEqual(machine.readyContext, rerouted)
    }

    // MARK: - Ineligible environments

    func testDisabledPreference_DiscardsAndStaysCold() {
        var machine = CaptureWarmStateMachine()
        let context = self.context()
        _ = machine.reconcile(with: context, enabled: true)
        machine.markReady(context)

        XCTAssertEqual(machine.reconcile(with: context, enabled: false), .discard)
        XCTAssertEqual(machine.phase, .cold)
        XCTAssertEqual(machine.reconcile(with: context, enabled: false), .none)
    }

    func testMissingMicrophonePermission_NeverStages() {
        var machine = CaptureWarmStateMachine()
        let denied = self.context(permissionGranted: false)
        XCTAssertEqual(machine.reconcile(with: denied, enabled: true), .none)
        XCTAssertEqual(machine.phase, .cold)
    }

    func testPreferredDeviceNeedingDefaultSwitch_NeverStages() {
        var machine = CaptureWarmStateMachine()
        let needsSwitch = self.context(requiresSwitch: true)
        XCTAssertEqual(machine.reconcile(with: needsSwitch, enabled: true), .none)
        XCTAssertEqual(machine.phase, .cold)
    }

    func testPermissionRevoked_DiscardsStagedRecorder() {
        var machine = CaptureWarmStateMachine()
        let granted = self.context()
        _ = machine.reconcile(with: granted, enabled: true)
        machine.markReady(granted)

        let revoked = self.context(permissionGranted: false)
        XCTAssertEqual(machine.reconcile(with: revoked, enabled: true), .discard)
        XCTAssertEqual(machine.phase, .cold)
    }

    // MARK: - Claiming

    func testClaim_FailsWhenEnvironmentDiffersFromStagedOne() {
        var machine = CaptureWarmStateMachine()
        let staged = self.context(device: "built-in-mic")
        _ = machine.reconcile(with: staged, enabled: true)
        machine.markReady(staged)

        XCTAssertFalse(machine.claim(for: self.context(device: "usb-mic")))
        XCTAssertEqual(machine.readyContext, staged)
    }

    func testClaim_FailsWhileStillStaging() {
        var machine = CaptureWarmStateMachine()
        let context = self.context()
        _ = machine.reconcile(with: context, enabled: true)

        XCTAssertFalse(machine.claim(for: context))
    }

    func testMarkFailed_ReturnsToColdSoTheNextTriggerRetries() {
        var machine = CaptureWarmStateMachine()
        let context = self.context()
        _ = machine.reconcile(with: context, enabled: true)

        machine.markFailed(context)
        XCTAssertEqual(machine.phase, .cold)
        XCTAssertEqual(machine.reconcile(with: context, enabled: true), .prepare(context))
    }

    func testMarkFailed_IgnoresStaleFailures() {
        var machine = CaptureWarmStateMachine()
        let staged = self.context(device: "usb-mic")
        _ = machine.reconcile(with: staged, enabled: true)

        machine.markFailed(self.context(device: "built-in-mic"))
        XCTAssertEqual(machine.phase, .warming(staged))
    }

    func testReset_DiscardsOnlyWhenSomethingIsStaged() {
        var machine = CaptureWarmStateMachine()
        XCTAssertEqual(machine.reset(), .none)

        let context = self.context()
        _ = machine.reconcile(with: context, enabled: true)
        XCTAssertEqual(machine.reset(), .discard)
        XCTAssertEqual(machine.phase, .cold)
    }
}
