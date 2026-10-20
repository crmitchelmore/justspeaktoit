import Foundation
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostCredentialEditorTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-editor-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40)
        )
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testTranscriptionAdmission_DrainsSettingsBeforeBlockedStorageAndClose() async throws {
        let controller = try XCTUnwrap(self.controller)
        let model = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopHostModels.provider(for: $0.id)?.apiKeyIdentifier == "openai.apiKey"
        })
        let entered = expectation(description: "queued transcription vault entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog(after: .seconds(30))
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let queue = DesktopSettingsQueue()
        queue.submit { await controller.beginKeySave("synthetic-transcription", modelIndex: model) }
        let orderedBusy = queue.read { await controller.busy }
        await queue.drain()
        let wasBusy = await orderedBusy.value
        XCTAssertTrue(wasBusy, "Recording must not overtake the admitted key edit")
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertTrue(gate.isBlocked, "Settings drain waited for native storage")
        let editor = await controller.providerCredentialEditTask
        await controller.beginKeySave("synthetic-must-not-write", modelIndex: model)
        await controller.stopProviderCredentialEdits()
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked)
        XCTAssertGreaterThan(report.unfinishedOperations, 0)
        let statuses = FakeLog.shared.allStatuses
        gate.release()
        await editor?.value
        let finished = await controller.activeOperations
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(FakeLog.shared.key("openai.apiKey"), "synthetic-transcription")
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }

    func testKeyBearingApply_DrainsAndCannotApplyOrRepublishAfterShutdown() async throws {
        let controller = try XCTUnwrap(self.controller)
        let before = await controller.postProcessingOptions()
        let entered = expectation(description: "queued post-processing vault entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog(after: .seconds(30))
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let fields = nativeFields(prompt: "must not apply after closing", key: "synthetic-key")
        let model = DesktopPostProcessing.remoteModels[0].id
        let queue = DesktopSettingsQueue()
        queue.submit {
            await controller.applyPostProcessingFromEditor(enabled: true, modelIdentifier: model, fields: fields) {
                XCTFail("Closed editor republished native controls")
            }
        }
        await queue.drain()
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertTrue(gate.isBlocked, "Settings drain waited for key-bearing Apply")
        let editor = await controller.providerCredentialEditTask
        await controller.stopProviderCredentialEdits()
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked)
        XCTAssertGreaterThan(report.unfinishedOperations, 0)
        gate.release()
        await editor?.value
        let after = await controller.postProcessingOptions()
        XCTAssertEqual(after.customPrompt, before.customPrompt)
        XCTAssertEqual(after.modelIdentifier, before.modelIdentifier)
        let owner = await controller.providerCredentialEditTask
        let finished = await controller.activeOperations
        XCTAssertNil(owner)
        XCTAssertEqual(finished, 0)
    }

    func testKeylessApply_RemainsOrderedBeforeTheNextSettingsSnapshot() async throws {
        let controller = try XCTUnwrap(self.controller)
        let completed = expectation(description: "keyless editor refreshed")
        let fields = nativeFields(prompt: "queued keyless prompt", key: "")
        let model = DesktopPostProcessing.remoteModels[0].id
        let queue = DesktopSettingsQueue()
        queue.submit {
            await controller.applyPostProcessingFromEditor(enabled: true, modelIdentifier: model, fields: fields) {
                completed.fulfill()
            }
        }
        let snapshot = queue.read { await controller.postProcessingOptions() }
        await queue.drain()
        let saved = await snapshot.value
        XCTAssertEqual(saved.customPrompt, fields.prompt)
        XCTAssertEqual(saved.modelIdentifier, model)
        let owner = await controller.providerCredentialEditTask
        XCTAssertNil(owner)
        await fulfillment(of: [completed], timeout: 10)
    }

    func testLiveKeyApply_QueuesLaterApplyAndCompletesEachOnceInOrder() async throws {
        let controller = try XCTUnwrap(self.controller)
        let entered = expectation(description: "live key editor vault entered")
        let completed = expectation(description: "live key editor refreshed")
        completed.expectedFulfillmentCount = 2
        completed.assertForOverFulfill = true
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog(after: .seconds(30))
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let model = DesktopPostProcessing.remoteModels[0].id
        await controller.applyPostProcessingFromEditor(
            enabled: true, modelIdentifier: model, fields: nativeFields(prompt: "original", key: "synthetic-key")
        ) { completed.fulfill() }
        await fulfillment(of: [entered], timeout: 10)
        let editor = await controller.providerCredentialEditTask
        await controller.applyPostProcessingFromEditor(
            enabled: false, modelIdentifier: model, fields: nativeFields(prompt: "competing", key: "")
        ) { completed.fulfill() }
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("queued after the current key operation") == true)
        gate.release()
        await editor?.value
        let saved = await controller.postProcessingOptions()
        XCTAssertEqual(saved.customPrompt, "competing")
        XCTAssertEqual(saved.mode, .disabled)
        let busy = await controller.busy
        XCTAssertFalse(busy)
        await fulfillment(of: [completed], timeout: 10)
    }

    func testEditBacklog_RefusesOverflowWithoutDroppingAcceptedOrder() async throws {
        let controller = try XCTUnwrap(self.controller)
        let entered = expectation(description: "backlogged editor vault entered")
        let completed = expectation(description: "accepted edits refreshed")
        completed.expectedFulfillmentCount = 9
        completed.assertForOverFulfill = true
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog(after: .seconds(30))
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let model = DesktopPostProcessing.remoteModels[0].id
        await controller.applyPostProcessingFromEditor(
            enabled: true, modelIdentifier: model, fields: nativeFields(prompt: "first", key: "synthetic-key")
        ) { completed.fulfill() }
        await fulfillment(of: [entered], timeout: 10)
        let editor = await controller.providerCredentialEditTask
        for index in 0..<8 {
            await controller.applyPostProcessingFromEditor(
                enabled: true, modelIdentifier: model, fields: nativeFields(prompt: "queued\(index)", key: "")
            ) { completed.fulfill() }
        }
        await controller.applyPostProcessingFromEditor(
            enabled: false, modelIdentifier: model, fields: nativeFields(prompt: "overflow", key: "")
        ) { XCTFail("An excess edit was admitted") }
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Too many provider key edits") == true)
        gate.release()
        await editor?.value
        let saved = await controller.postProcessingOptions()
        XCTAssertEqual(saved.customPrompt, "queued7")
        XCTAssertEqual(saved.mode, .remote)
        await fulfillment(of: [completed], timeout: 10)
    }

    func testStoppedEditors_RefuseNewWorkWithoutTouchingTheVaultOrControls() async throws {
        let controller = try XCTUnwrap(self.controller)
        FakeLog.shared.installKeyWriteHook { _, _ in XCTFail("Stopped editor touched native storage") }
        await controller.stopProviderCredentialEdits()
        await controller.beginKeySave("synthetic-key", modelIndex: 0)
        await controller.applyPostProcessingFromEditor(
            enabled: true, modelIdentifier: DesktopPostProcessing.remoteModels[0].id,
            fields: nativeFields(prompt: "stopped", key: "synthetic-key")
        ) { XCTFail("Stopped editor republished controls") }
        let editor = await controller.providerCredentialEditTask
        let active = await controller.activeOperations
        XCTAssertNil(editor)
        XCTAssertEqual(active, 0)
    }

    private func nativeFields(prompt: String, key: String) -> DesktopPostProcessing.NativeFields {
        .init(prompt: prompt, key: key, includeLexiconDirectives: true, includeContextTags: false)
    }
}
