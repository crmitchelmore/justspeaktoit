import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// First-run guide persistence through the shared controller.
final class DesktopHostOnboardingTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>?

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await controller?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func start() throws -> DesktopHostController<FakePlatform> {
        DesktopHostOnboarding.adoptExistingInstall(directory: directory)
        let created = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        controller = created
        return created
    }

    func testAFreshInstallNeedsTheGuideUntilItIsFinished() async throws {
        let controller = try start()
        let needed = await controller.needsOnboarding()
        XCTAssertTrue(needed)
        await controller.recordOnboardingStep(.transcriptionRoute)
        let midway = await controller.onboardingState()
        XCTAssertEqual(midway.resumeStep, .transcriptionRoute)
        XCTAssertFalse(midway.hasCompletedOnboarding)
        await controller.recordOnboardingStep(.done)
        let finished = await controller.needsOnboarding()
        XCTAssertFalse(finished)
    }

    func testSkippingCompletesTheGuideAcrossLaunches() async throws {
        let first = try start()
        await first.completeOnboarding()
        await first.close()
        let second = try start()
        let needed = await second.needsOnboarding()
        XCTAssertFalse(needed)
        let data = try Data(contentsOf: DesktopHostOnboarding.stateURL(in: directory))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object[DesktopOnboardingState.completionKey] as? Bool, true)
    }

    func testAnUpgradedInstallIsNotShownTheFirstRunGuide() async throws {
        let saved = try JSONEncoder().encode(DesktopHostController<FakePlatform>.Settings())
        try saved.write(to: directory.appendingPathComponent("settings.json"))
        let controller = try start()
        let needed = await controller.needsOnboarding()
        XCTAssertFalse(needed)
    }

    func testAClosedControllerNeverOpensTheGuide() async throws {
        let controller = try start()
        await controller.close()
        let needed = await controller.needsOnboarding()
        XCTAssertFalse(needed)
    }

    func testTheRouteStepSaysWhyARemoteModelIsNotReady() async throws {
        let controller = try start()
        let summary = await controller.onboardingRouteSummary()
        XCTAssertFalse(summary.ready)
        XCTAssertFalse(summary.text.isEmpty)
    }

    func testABlockedMicrophoneIsNamedInTheReadyStatus() async throws {
        let controller = try start()
        let blocked = DesktopPermissionItem(kind: .microphone, status: .denied, detail: "Microphone access is off.")
        await controller.setPermissionWarning([blocked])
        await controller.ready()
        let expected = try XCTUnwrap(DesktopPermissionSummary.blockingMessage([blocked]))
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains(expected) })
    }
}
