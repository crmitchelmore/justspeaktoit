import Foundation
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest
@testable import SpeakDesktopSync

final class DesktopComparisonHostSyncTests: XCTestCase {
    func testNativeConsentRetryAndEditorCloseUseSeparateOwnedHooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let log = ComparisonSyncHookLog()
        await controller.installComparisonSync(log.hooks)
        await controller.comparisonEvent(100, text: "", index: 0)
        let before = await controller.comparisonSyncPresentation()
        XCTAssertFalse(before.controls.enabled)
        XCTAssertTrue(before.controls.available)
        await controller.comparisonEvent(121, text: "", index: 1)
        let enabled = await controller.comparisonSyncPresentation()
        XCTAssertTrue(enabled.controls.enabled)
        XCTAssertEqual(log.changes, 1)
        await controller.comparisonEvent(122, text: "", index: 0)
        XCTAssertEqual(log.changes, 2)
        await controller.comparisonEvent(121, text: "", index: 0)
        XCTAssertEqual(log.changes, 3)
        let disabled = await controller.comparisonSyncPresentation()
        XCTAssertFalse(disabled.controls.enabled)
        await controller.comparisonEvent(123, text: "", index: 0)
        let visible = await controller.comparisonVisible
        XCTAssertFalse(visible)
        await controller.close()
    }

    func testClosedHostCannotInstallHooksOrAdmitConsentAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.close()
        let log = ComparisonSyncHookLog()
        await controller.installComparisonSync(log.hooks)
        await controller.comparisonEvent(121, text: "", index: 1)
        await controller.comparisonEvent(122, text: "", index: 0)
        XCTAssertEqual(log.changes, 0)
        XCTAssertFalse(log.enabled)
    }
}

private final class ComparisonSyncHookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var optedIn = false
    private var triggers = 0
    var changes: Int { lock.withLock { triggers } }
    var enabled: Bool { lock.withLock { optedIn } }

    var hooks: DesktopHostComparisonSyncHooks {
        .init(
            status: { [self] in
                DesktopCloudSyncStatus(
                    unavailableReason: nil, isSignedIn: true, historyEnabled: false, apiKeyImportEnabled: false,
                    comparisonEnabled: enabled, isSyncing: false, lastSuccessfulSync: nil, lastError: nil
                )
            },
            setEnabled: { [self] value in lock.withLock { optedIn = value } },
            changed: { [self] in lock.withLock { triggers += 1 } }
        )
    }
}
