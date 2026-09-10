import Foundation
@testable import SpeakCore
import XCTest

/// Issue #997. A health screen that lies is worse than no health screen, so
/// what is proved here is not that the rows render: it is that a row never
/// claims more than the evidence behind it, that "not established" never comes
/// out green, and that no free-form string can reach the screen.
final class CaptureHealthReportTests: XCTestCase {
    // MARK: - Evidence kinds are honest and fixed

    func testEveryCheckDeclaresWhatKindOfEvidenceItIs() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        for check in report.checks {
            XCTAssertEqual(check.evidence, check.id.evidence)
            XCTAssertFalse(check.title.isEmpty)
            XCTAssertFalse(check.detail.isEmpty)
        }
    }

    func testPermissionRowsAreConfigurationChecksNotWorkingChecks() {
        // The whole #952 lesson: a granted switch is not a working capture.
        for id in [CaptureHealthCheckID.microphonePermission, .speechPermission,
                   .liveActivities, .speechAssets] {
            XCTAssertEqual(id.evidence, .configuration, "\(id)")
        }
    }

    func testTheRowsThatRunSomethingAreMarkedExercised() {
        for id in [CaptureHealthCheckID.appGroupContainer, .credentialStore,
                   .credentialAccessibility, .safetyRecordingStorage, .microphoneSelfTest] {
            XCTAssertEqual(id.evidence, .exercised, "\(id)")
        }
    }

    func testTheRowsThatReportPastRunsAreMarkedObserved() {
        for id in [CaptureHealthCheckID.keyboardReadiness, .recentCaptures, .unrecoveredCaptures] {
            XCTAssertEqual(id.evidence, .observed, "\(id)")
        }
    }

    func testEveryCheckAppearsExactlyOnce() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        let ids = report.checks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(ids), Set(CaptureHealthCheckID.allCases))
    }

    // MARK: - An empty probe is never green

    func testAnUnprobedScreenReportsUndeterminedRatherThanHealthy() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        XCTAssertNotEqual(report.overall, .healthy)
        XCTAssertEqual(report.check(.microphoneSelfTest)?.status, .undetermined)
        XCTAssertEqual(report.check(.appGroupContainer)?.status, .undetermined)
    }

    func testUndeterminedOutranksHealthyInTheSummary() {
        let report = CaptureHealthReport(checks: [
            CaptureHealthCheck(id: .microphonePermission, status: .healthy, detail: "a"),
            CaptureHealthCheck(id: .appGroupContainer, status: .undetermined, detail: "b")
        ])
        XCTAssertEqual(report.overall, .undetermined)
    }

    func testBrokenOutranksEverything() {
        let report = CaptureHealthReport(checks: [
            CaptureHealthCheck(id: .microphonePermission, status: .healthy, detail: "a"),
            CaptureHealthCheck(id: .appGroupContainer, status: .attention, detail: "b"),
            CaptureHealthCheck(id: .speechAssets, status: .broken, detail: "c"),
            CaptureHealthCheck(id: .recentCaptures, status: .undetermined, detail: "d")
        ])
        XCTAssertEqual(report.overall, .broken)
        XCTAssertEqual(report.problems.count, 2)
    }

    func testAReportOfOnlyNotApplicableRowsIsUndeterminedNotHealthy() {
        let report = CaptureHealthReport(checks: [
            CaptureHealthCheck(id: .liveActivities, status: .notApplicable, detail: "a")
        ])
        XCTAssertEqual(report.overall, .undetermined)
    }

    // MARK: - The individual verdicts

    func testADeniedMicrophoneIsBroken() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(microphone: .denied))
        XCTAssertEqual(report.check(.microphonePermission)?.status, .broken)
    }

    func testAGrantedMicrophoneIsHealthyButStillOnlyASetting() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(microphone: .granted))
        let check = report.check(.microphonePermission)
        XCTAssertEqual(check?.status, .healthy)
        XCTAssertEqual(check?.evidence, .configuration)
    }

    func testAFailedAppGroupRoundTripIsBroken() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(appGroupRoundTrip: .failed)
        )
        XCTAssertEqual(report.check(.appGroupContainer)?.status, .broken)
    }

    func testAnOnDeviceModelNeedsNoKeyAndSaysSo() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(credentialLookup: nil))
        XCTAssertEqual(report.check(.credentialStore)?.status, .notApplicable)
    }

    func testWhenUnlockedKeyStorageIsReportedBroken() {
        // Issue #930: this is the silent downgrade to Apple Speech on a
        // locked-device capture, and it is the row this screen exists for.
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(credentialAccessibility: .whenUnlocked)
        )
        XCTAssertEqual(report.check(.credentialAccessibility)?.status, .broken)
    }

    func testAfterFirstUnlockKeyStorageIsHealthy() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(credentialAccessibility: .afterFirstUnlock)
        )
        XCTAssertEqual(report.check(.credentialAccessibility)?.status, .healthy)
    }

    func testNoStoredKeyLeavesTheAccessibilityRowUndetermined() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        XCTAssertEqual(report.check(.credentialAccessibility)?.status, .undetermined)
    }

    func testLiveActivitiesOffIsAttentionNotBroken() {
        // Capture still works without one; only the Lock Screen stop does not.
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(liveActivitiesEnabled: false)
        )
        XCTAssertEqual(report.check(.liveActivities)?.status, .attention)
    }

    func testAnUnsupportedLocaleForTheOnDeviceModelIsBroken() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(speechAssets: .unsupportedLocale)
        )
        XCTAssertEqual(report.check(.speechAssets)?.status, .broken)
    }

    func testAMissingModelIsAttentionAndWarnsAboutTheDownload() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(speechAssets: .notInstalled)
        )
        let check = report.check(.speechAssets)
        XCTAssertEqual(check?.status, .attention)
        XCTAssertTrue(check?.detail.contains("download") == true)
    }

    // MARK: - Observed rows

    func testAKeyboardHeartbeatOlderThanItsWindowIsAttention() {
        let stale = Int(InstantDictationReadinessPolicy.sessionWindowSeconds) + 60
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(keyboardHeartbeatAgeSeconds: stale)
        )
        XCTAssertEqual(report.check(.keyboardReadiness)?.status, .attention)
    }

    func testAFreshKeyboardHeartbeatIsHealthy() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(keyboardHeartbeatAgeSeconds: 30, keyboardResumeAttemptsSpent: 0)
        )
        XCTAssertEqual(report.check(.keyboardReadiness)?.status, .healthy)
    }

    func testAKeyboardThatSpentAllItsResumeAttemptsIsAttentionEvenWhenFresh() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(
            keyboardHeartbeatAgeSeconds: 30,
            keyboardResumeAttemptsSpent: InstantDictationReadinessPolicy.maximumResumeAttempts
        ))
        XCTAssertEqual(report.check(.keyboardReadiness)?.status, .attention)
    }

    func testAKeyboardThatNeverReportedIsUndetermined() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        XCTAssertEqual(report.check(.keyboardReadiness)?.status, .undetermined)
    }

    func testEveryWatchdogOutcomeHasItsOwnSentence() {
        var seen: Set<String> = []
        for outcome in CaptureHealthLastOutcome.allCases {
            let report = CaptureHealthReport.build(
                from: CaptureHealthProbe(lastCaptureOutcome: outcome, lastCaptureAgeSeconds: 120)
            )
            let text = report.check(.recentCaptures)?.detail ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(seen.insert(text).inserted, "\(outcome) reuses another outcome's words")
        }
    }

    func testACaptureThatReceivedNoAudioIsBroken() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(lastCaptureOutcome: .noInput)
        )
        XCTAssertEqual(report.check(.recentCaptures)?.status, .broken)
    }

    // MARK: - The bridge to issue #992

    func testUnrecoveredAudioIsSurfacedAndSaysNothingWasDeleted() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(recoverableCaptureCount: 2)
        )
        let check = report.check(.unrecoveredCaptures)
        XCTAssertEqual(check?.status, .attention)
        XCTAssertTrue(check?.detail.contains("kept") == true, check?.detail ?? "")
    }

    func testAudioKeptBecauseTheDeviceCouldNotTellIsAlsoSurfaced() {
        let report = CaptureHealthReport.build(
            from: CaptureHealthProbe(uncertainCaptureCount: 1)
        )
        let check = report.check(.unrecoveredCaptures)
        XCTAssertEqual(check?.status, .attention)
        XCTAssertTrue(check?.detail.contains("Nothing was deleted") == true, check?.detail ?? "")
    }

    func testNothingWaitingIsHealthy() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        XCTAssertEqual(report.check(.unrecoveredCaptures)?.status, .healthy)
    }

    // MARK: - Self-test row

    func testAnUnrunSelfTestIsUndeterminedAndSaysWhatRunningItWouldSettle() {
        let report = CaptureHealthReport.build(from: CaptureHealthProbe())
        let check = report.check(.microphoneSelfTest)
        XCTAssertEqual(check?.status, .undetermined)
        XCTAssertTrue(check?.detail.contains("actually") == true, check?.detail ?? "")
    }

    func testAPassedSelfTestReportsTheBuffersItActuallySaw() {
        let result = CaptureSelfTestResult(
            outcome: .passed,
            observedBuffers: 7,
            elapsedMilliseconds: 340,
            stageMilliseconds: [:]
        )
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(selfTest: result))
        let check = report.check(.microphoneSelfTest)
        XCTAssertEqual(check?.status, .healthy)
        XCTAssertTrue(check?.detail.contains("7 audio buffers") == true, check?.detail ?? "")
    }

    func testASelfTestThatOpenedTheMicrophoneAndHeardNothingIsBroken() {
        let result = CaptureSelfTestResult(
            outcome: .failed(.firstInput),
            observedBuffers: 0,
            elapsedMilliseconds: 2000,
            stageMilliseconds: [:]
        )
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(selfTest: result))
        XCTAssertEqual(report.check(.microphoneSelfTest)?.status, .broken)
    }

    func testACancelledSelfTestIsUndeterminedAndSaysTheMicrophoneWasClosed() {
        let result = CaptureSelfTestResult(
            outcome: .cancelled,
            observedBuffers: 0,
            elapsedMilliseconds: 90,
            stageMilliseconds: [:]
        )
        let report = CaptureHealthReport.build(from: CaptureHealthProbe(selfTest: result))
        let check = report.check(.microphoneSelfTest)
        XCTAssertEqual(check?.status, .undetermined)
        XCTAssertTrue(check?.detail.contains("closed") == true, check?.detail ?? "")
    }

    // MARK: - Wording

    func testDurationsAreWholeUnitsAndNeverNegative() {
        XCTAssertEqual(CaptureHealthReport.duration(-5), "0s")
        XCTAssertEqual(CaptureHealthReport.duration(45), "45s")
        XCTAssertEqual(CaptureHealthReport.duration(600), "10m")
        XCTAssertEqual(CaptureHealthReport.duration(7200), "2h")
        XCTAssertEqual(CaptureHealthReport.duration(172_800), "2d")
    }
}
