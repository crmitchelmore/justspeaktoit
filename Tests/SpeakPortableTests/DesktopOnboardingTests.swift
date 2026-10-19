import Foundation
import XCTest

@testable import SpeakCore

/// The shared first-run guide and permission summary every desktop host shows.
final class DesktopOnboardingTests: XCTestCase {
    func testStepsRunInTheMacOrderAndEndAtDone() {
        XCTAssertEqual(DesktopOnboardingStep.allCases, [
            .welcome, .microphone, .textInsertion, .transcriptionRoute, .hotkeyPractice, .postProcessing, .done
        ])
        XCTAssertNil(DesktopOnboardingStep.welcome.previous)
        XCTAssertEqual(DesktopOnboardingStep.welcome.next, .microphone)
        XCTAssertEqual(DesktopOnboardingStep.postProcessing.next, .done)
        XCTAssertNil(DesktopOnboardingStep.done.next)
        XCTAssertEqual(DesktopOnboardingStep.microphone.progress, "Step 2 of 7")
        XCTAssertEqual(DesktopOnboardingStep.allCases.filter(\.isOptional), [.postProcessing])
    }

    func testRouteStepOffersBothRemoteAndLocal() {
        XCTAssertEqual(DesktopOnboardingStep.transcriptionRoute.actions, [.chooseRemoteProvider, .downloadLocalModel])
        XCTAssertTrue(DesktopOnboardingStep.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        XCTAssertTrue(DesktopOnboardingAction.allCases.allSatisfy { !$0.title.isEmpty })
    }

    func testStateUsesTheMacCompletionKeyAndRoundTrips() throws {
        let state = DesktopOnboardingState(hasCompletedOnboarding: false, lastStep: .transcriptionRoute)
        let data = try state.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object[DesktopOnboardingState.completionKey] as? Bool, false)
        XCTAssertEqual(DesktopOnboardingState.completionKey, "hasCompletedOnboarding")
        XCTAssertEqual(DesktopOnboardingState.load(stateData: data, hasExistingSettings: true), state)
    }

    func testFreshInstallsSeeTheGuideAndUpgradesDoNot() {
        XCTAssertFalse(DesktopOnboardingState.load(stateData: nil, hasExistingSettings: false).hasCompletedOnboarding)
        XCTAssertTrue(DesktopOnboardingState.load(stateData: nil, hasExistingSettings: true).hasCompletedOnboarding)
        // An unreadable file never traps the user in the guide on every launch.
        XCTAssertTrue(
            DesktopOnboardingState.load(stateData: Data("{".utf8), hasExistingSettings: false).hasCompletedOnboarding
        )
    }

    func testResumeStepContinuesAnUnfinishedGuide() {
        XCTAssertEqual(DesktopOnboardingState().resumeStep, .welcome)
        XCTAssertEqual(DesktopOnboardingState(lastStep: .hotkeyPractice).resumeStep, .hotkeyPractice)
        XCTAssertEqual(DesktopOnboardingState(lastStep: .done).resumeStep, .welcome)
        XCTAssertEqual(
            DesktopOnboardingState(hasCompletedOnboarding: true, lastStep: .microphone).resumeStep, .welcome
        )
    }

    func testOnlyEssentialProblemsBlockAndWarnTheDashboard() {
        let fine: [DesktopPermissionItem] = [
            .init(kind: .microphone, status: .granted, detail: ""),
            .init(kind: .textInsertion, status: .granted, detail: ""),
            .init(kind: .notifications, status: .off, detail: ""),
            .init(kind: .startup, status: .denied, detail: "")
        ]
        XCTAssertNil(DesktopPermissionSummary.blockingMessage(fine))
        XCTAssertEqual(
            DesktopPermissionSummary.recheckMessage(fine), "All required permissions are detected for this app."
        )

        var micBlocked = fine
        micBlocked[0].status = .denied
        XCTAssertEqual(
            DesktopPermissionSummary.blockingMessage(micBlocked),
            "Microphone: blocked. Open Permissions to fix it."
        )
        XCTAssertEqual(DesktopPermissionSummary.recheckMessage(micBlocked), "Still not detected: Microphone.")

        var bothBlocked = micBlocked
        bothBlocked[1].status = .warning
        XCTAssertEqual(
            DesktopPermissionSummary.blockingMessage(bothBlocked),
            "Microphone and Text insertion need attention. Open Permissions to fix them."
        )
    }

    func testUnknownEssentialStatusIsReportedButDoesNotBlock() {
        let items: [DesktopPermissionItem] = [.init(kind: .microphone, status: .unknown, detail: "")]
        XCTAssertNil(DesktopPermissionSummary.blockingMessage(items))
        XCTAssertEqual(DesktopPermissionSummary.recheckMessage(items), "Still not detected: Microphone.")
    }
}
