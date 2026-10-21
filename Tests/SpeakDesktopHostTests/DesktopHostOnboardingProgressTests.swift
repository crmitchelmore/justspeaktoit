import Foundation
import SpeakCore
import SpeakDesktopHost
import XCTest

final class DesktopHostOnboardingProgressTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>?

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await controller?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func start() throws -> DesktopHostController<FakePlatform> {
        let created = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        controller = created
        return created
    }

    func testEveryStepUsesTheCanonicalCompletionAndResumeRule() async throws {
        let controller = try start()
        for step in DesktopOnboardingStep.allCases {
            try await controller.persistOnboardingState(.init())
            try await controller.persistOnboardingStep(step)
            let saved = try await controller.readOnboardingState()
            XCTAssertEqual(saved.lastStep, step)
            XCTAssertEqual(saved.hasCompletedOnboarding, step == .done)
            XCTAssertEqual(saved.resumeStep, step == .done ? .welcome : step)
        }
    }

    func testManuallyRerunningACompletedGuideKeepsCompletionSticky() async throws {
        let controller = try start()
        try await controller.persistOnboardingState(.init(hasCompletedOnboarding: true, lastStep: .done))
        for step in DesktopOnboardingStep.allCases {
            try await controller.persistOnboardingStep(step)
            let saved = try await controller.readOnboardingState()
            XCTAssertTrue(saved.hasCompletedOnboarding)
            XCTAssertEqual(saved.lastStep, step)
            XCTAssertEqual(saved.resumeStep, .welcome)
        }
    }

    func testManualUpgradeProgressDoesNotReintroduceFirstRunOrRewriteSettings() async throws {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let before = try JSONEncoder().encode(DesktopHostController<FakePlatform>.Settings())
        try before.write(to: settingsURL)
        XCTAssertFalse(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
        let controller = try start()
        try await controller.persistOnboardingStep(.microphone, preservingCompletion: true)
        let saved = try await controller.readOnboardingState()
        XCTAssertTrue(saved.hasCompletedOnboarding)
        XCTAssertEqual(saved.lastStep, .microphone)
        XCTAssertFalse(try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory))
        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
    }

    func testRevocationAfterReadDoesNotPublishTheNextStep() async throws {
        let controller = try start()
        try await controller.persistOnboardingState(.init(lastStep: .microphone))
        let stateURL = DesktopHostOnboarding.stateURL(in: directory)
        let before = try Data(contentsOf: stateURL)
        let checks = OnboardingProgressChecks()
        do {
            try await controller.persistOnboardingStep(.done, checkCancellation: {
                if checks.next() == 2 { throw CancellationError() }
            })
            XCTFail("A revoked guide must not save the next step.")
        } catch is CancellationError {
            XCTAssertEqual(checks.count, 2)
            XCTAssertEqual(try Data(contentsOf: stateURL), before)
        }
    }

    func testCancellationBeforeAdmissionCreatesNoGuideState() async throws {
        let controller = try start()
        do {
            try await controller.persistOnboardingStep(.done, checkCancellation: { throw CancellationError() })
            XCTFail("A cancelled request must not create a completion file.")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: DesktopHostOnboarding.stateURL(in: directory).path))
        }
    }

    func testCancelledTasksCannotSaveProgressOrCompleteTheGuide() async throws {
        let controller = try start()
        for savesStep in [false, true] {
            let operation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if savesStep {
                    try await controller.persistOnboardingStep(.done)
                } else {
                    try await controller.persistOnboardingState(.init(hasCompletedOnboarding: true, lastStep: .done))
                }
            }
            do {
                try await operation.value
                XCTFail("A cancelled task must not mark setup complete.")
            } catch is CancellationError {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: DesktopHostOnboarding.stateURL(in: directory).path)
                )
            }
        }
    }

    func testAWriteFailureAfterSuccessfulReadIsReported() async throws {
        let controller = try start()
        let stateURL = DesktopHostOnboarding.stateURL(in: directory)
        let checks = OnboardingProgressChecks()
        do {
            try await controller.persistOnboardingStep(.done, checkCancellation: {
                if checks.next() == 2 {
                    try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
                }
            })
            XCTFail("Failed persistence must not be acknowledged as progress.")
        } catch {
            var isDirectory: ObjCBool = false
            XCTAssertEqual(checks.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testClosedControllerRejectsStepProgressWithoutCreatingState() async throws {
        let controller = try start()
        await controller.close()
        do {
            try await controller.persistOnboardingStep(.done)
            XCTFail("A closed controller must not save progress.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: DesktopHostOnboarding.stateURL(in: directory).path))
        }
    }

    func testUnreadableProgressIsNotReplacedByFreshProgress() async throws {
        let controller = try start()
        let stateURL = DesktopHostOnboarding.stateURL(in: directory)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        do {
            try await controller.persistOnboardingStep(.done)
            XCTFail("An unreadable guide state must not be overwritten.")
        } catch {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }
}

private final class OnboardingProgressChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
