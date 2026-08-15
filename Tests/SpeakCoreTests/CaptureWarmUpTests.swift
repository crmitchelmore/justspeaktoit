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

    func testAuxiliaryRecordingStart_DiscardsReadyWarmState() {
        var machine = CaptureWarmStateMachine()
        let context = self.context()
        _ = machine.reconcile(with: context, enabled: true)
        machine.markReady(context)

        XCTAssertEqual(machine.recordingBeganWithoutClaim(), .discard)
        XCTAssertEqual(machine.phase, .cold)
        XCTAssertFalse(machine.claim(for: context))
    }
}

final class CaptureStagingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let temporaryDirectory = URL(fileURLWithPath: "/tmp/session", isDirectory: true)
    private let recordingsDirectory = URL(fileURLWithPath: "/Users/test/Recordings", isDirectory: true)

    // MARK: - Location

    func testStagedFile_NeverLandsInTheRecordingsDirectory() {
        for sharesVolume in [true, false] {
            let directory = CaptureStaging.directory(
                temporaryDirectory: self.temporaryDirectory,
                recordingsDirectory: self.recordingsDirectory,
                sharesVolume: sharesVolume
            )
            XCTAssertNotEqual(directory.standardizedFileURL, self.recordingsDirectory.standardizedFileURL)
            XCTAssertEqual(directory.lastPathComponent, CaptureStaging.folderName)
        }
    }

    func testSharedVolume_StagesInTheTemporaryDirectory() {
        XCTAssertEqual(
            CaptureStaging.directory(
                temporaryDirectory: self.temporaryDirectory,
                recordingsDirectory: self.recordingsDirectory,
                sharesVolume: true
            ),
            self.temporaryDirectory.appendingPathComponent(CaptureStaging.folderName, isDirectory: true)
        )
    }

    func testSeparateVolume_StagesBesideTheRecordingsSoClaimingStaysARename() {
        XCTAssertEqual(
            CaptureStaging.directory(
                temporaryDirectory: self.temporaryDirectory,
                recordingsDirectory: self.recordingsDirectory,
                sharesVolume: false
            ),
            self.recordingsDirectory.appendingPathComponent(CaptureStaging.folderName, isDirectory: true)
        )
    }

    func testStagingFolder_IsHiddenFromFinderAndFromRecordingListings() {
        XCTAssertTrue(CaptureStaging.folderName.hasPrefix("."))
    }

    // MARK: - Sweep

    func testFreshlyStagedFile_IsNeverSwept() {
        XCTAssertFalse(
            CaptureStaging.isLeftover(modifiedAt: self.now.addingTimeInterval(-30), now: self.now)
        )
        XCTAssertFalse(CaptureStaging.isLeftover(modifiedAt: self.now, now: self.now))
    }

    func testStagedFileFromAnEarlierRun_IsSwept() {
        XCTAssertTrue(
            CaptureStaging.isLeftover(
                modifiedAt: self.now.addingTimeInterval(-CaptureStaging.leftoverAge),
                now: self.now
            )
        )
    }

    func testAbandonedInPlaceStage_IsSweptFromTheRecordingsDirectory() {
        XCTAssertTrue(
            CaptureStaging.isAbandonedInPlaceStage(
                fileName: "Recording-\(UUID().uuidString).m4a",
                byteSize: 28,
                modifiedAt: self.now.addingTimeInterval(-600),
                now: self.now
            )
        )
    }

    func testFileHoldingAudio_IsLeftAlone() {
        XCTAssertFalse(
            CaptureStaging.isAbandonedInPlaceStage(
                fileName: "Recording-\(UUID().uuidString).m4a",
                byteSize: CaptureStaging.inPlaceStageMaxBytes + 1,
                modifiedAt: self.now.addingTimeInterval(-600),
                now: self.now
            )
        )
    }

    func testRecentOrForeignFiles_AreLeftAlone() {
        let identifier = UUID().uuidString
        XCTAssertFalse(
            CaptureStaging.isAbandonedInPlaceStage(
                fileName: "Recording-\(identifier).m4a",
                byteSize: 28,
                modifiedAt: self.now.addingTimeInterval(-30),
                now: self.now
            ),
            "a file the running app may still own must survive"
        )
        for name in [
            "Imported-\(identifier).m4a",
            "Recording-\(identifier).wav",
            "Recording-notauuid.m4a",
            "Interview.m4a"
        ] {
            XCTAssertFalse(
                CaptureStaging.isAbandonedInPlaceStage(
                    fileName: name,
                    byteSize: 28,
                    modifiedAt: self.now.addingTimeInterval(-600),
                    now: self.now
                ),
                "\(name) is not a staged file"
            )
        }
    }
}
