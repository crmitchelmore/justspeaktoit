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

    func testCheckedPersistenceRoundTripsWithoutRewritingSettings() async throws {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let before = try JSONEncoder().encode(DesktopHostController<FakePlatform>.Settings())
        try before.write(to: settingsURL)
        let controller = try start()
        let state = DesktopOnboardingState(lastStep: .hotkeyPractice)
        try await controller.persistOnboardingState(state)
        let saved = try await controller.readOnboardingState()
        XCTAssertEqual(saved, state)
        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
    }

    func testCheckedPersistenceReportsWriteFailureWithoutCompleting() async throws {
        let controller = try start()
        let stateURL = DesktopHostOnboarding.stateURL(in: directory)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        do {
            try await controller.persistOnboardingState(.init(hasCompletedOnboarding: true, lastStep: .done))
            XCTFail("A guide must not acknowledge a failed write.")
        } catch {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testCheckedReadReportsUnreadableState() async throws {
        let controller = try start()
        try FileManager.default.createDirectory(
            at: DesktopHostOnboarding.stateURL(in: directory), withIntermediateDirectories: false
        )
        do {
            _ = try await controller.readOnboardingState()
            XCTFail("An unreadable state must be reported, not treated as fresh progress.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testCheckedPersistenceRefusesAfterCloseAndPreservesLastStep() async throws {
        let controller = try start()
        try await controller.persistOnboardingState(.init(lastStep: .microphone))
        let stateURL = DesktopHostOnboarding.stateURL(in: directory)
        let before = try Data(contentsOf: stateURL)
        await controller.close()
        do {
            try await controller.persistOnboardingState(.init(hasCompletedOnboarding: true, lastStep: .done))
            XCTFail("A closed controller must not acknowledge setup completion.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: stateURL), before)
        }
    }

    func testPrelaunchFreshInstallNeedsSetupWithoutCreatingFiles() throws {
        XCTAssertTrue(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DesktopHostOnboarding.stateURL(in: directory).path))
    }

    func testPrelaunchUpgradeDoesNotOpenSetupOrAdoptStateSilently() throws {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let saved = try JSONEncoder().encode(DesktopHostController<FakePlatform>.Settings())
        try saved.write(to: settingsURL)
        XCTAssertFalse(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
        XCTAssertEqual(try Data(contentsOf: settingsURL), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DesktopHostOnboarding.stateURL(in: directory).path))
    }

    func testPrelaunchUnfinishedStateOverridesExistingSettingsWithoutRewriting() throws {
        try Data("{}".utf8).write(to: directory.appendingPathComponent("settings.json"))
        let url = DesktopHostOnboarding.stateURL(in: directory)
        let saved = try DesktopOnboardingState(lastStep: .textInsertion).encoded()
        try saved.write(to: url)
        XCTAssertTrue(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testPrelaunchCompletedStateDoesNotOpenSetup() throws {
        try DesktopOnboardingState(hasCompletedOnboarding: true, lastStep: .done).encoded()
            .write(to: DesktopHostOnboarding.stateURL(in: directory))
        XCTAssertFalse(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
    }

    func testPrelaunchMalformedStateKeepsTheCanonicalNoAutomaticSetupRule() throws {
        let url = DesktopHostOnboarding.stateURL(in: directory)
        let saved = Data("not JSON".utf8)
        try saved.write(to: url)
        XCTAssertFalse(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testPrelaunchUnreadableStateIsReported() throws {
        try FileManager.default.createDirectory(
            at: DesktopHostOnboarding.stateURL(in: directory), withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
    }
}
