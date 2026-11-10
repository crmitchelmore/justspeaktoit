import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostTroubleshootingTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("troubleshooting-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        FakeLog.shared.setKey("", name: "openrouter.apiKey")
        await controller.savePostProcessing(enabled: true, modelIndex: 0, prompt: "Synthetic prompt.", key: "")
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingCredential_FixPreservesModelAndPromptAndSurvivesRestart() async throws {
        let snapshot = await configuration()
        XCTAssertTrue(snapshot.findings.contains { $0.fix == .disablePostProcessing })
        try await controller.disablePostProcessingForTroubleshooting(expected: snapshot.processing)
        let saved = await controller.postProcessingOptions()
        XCTAssertEqual(saved.mode, .disabled)
        XCTAssertEqual(saved.modelIdentifier, snapshot.processing.modelIdentifier)
        XCTAssertEqual(saved.customPrompt, snapshot.processing.customPrompt)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restarted = await controller.postProcessingOptions()
        XCTAssertEqual(restarted, saved)
    }

    func testNewCredential_RefusesCleanupFix() async throws {
        let snapshot = await configuration()
        FakeLog.shared.setKey("new-synthetic-value", name: "openrouter.apiKey")
        do {
            try await controller.disablePostProcessingForTroubleshooting(expected: snapshot.processing)
            XCTFail("A newly available credential must prevent the fix.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("A key is now available"))
        }
        let saved = await controller.postProcessingOptions()
        XCTAssertEqual(saved, snapshot.processing)
    }

    func testChangedProcessing_RefusesStaleFix() async throws {
        let snapshot = await configuration()
        await controller.savePostProcessing(enabled: true, modelIndex: 0, prompt: "A newer prompt.", key: "")
        do {
            try await controller.disablePostProcessingForTroubleshooting(expected: snapshot.processing)
            XCTFail("A stale report must not disable newer settings.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Post-processing changed"))
        }
        let saved = await controller.postProcessingOptions()
        XCTAssertNotEqual(saved.mode, .disabled)
        XCTAssertEqual(saved.customPrompt, "A newer prompt.")
    }

    func testClosedController_RefusesFix() async throws {
        let snapshot = await configuration()
        await controller.close()
        do {
            try await controller.disablePostProcessingForTroubleshooting(expected: snapshot.processing)
            XCTFail("A closed controller must refuse fixes.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Wait for the current operation"))
        }
    }

    func testClipboardPolicy_UsesTheEffectivePlatformCapability() async {
        let restored = await controller.troubleshootingConfiguration(
            shortcutName: "Synthetic", shortcutInstructions: "Synthetic", restoreClipboard: true
        )
        XCTAssertTrue(restored.findings.contains { $0.fix == .keepTranscriptOnClipboard })
        let retained = await configuration()
        XCTAssertFalse(retained.findings.contains { $0.fix == .keepTranscriptOnClipboard })
    }

    private func configuration() async -> DesktopHostTroubleshootingConfiguration {
        await controller.troubleshootingConfiguration(
            shortcutName: "Synthetic shortcut", shortcutInstructions: "Synthetic instructions", restoreClipboard: false
        )
    }
}
