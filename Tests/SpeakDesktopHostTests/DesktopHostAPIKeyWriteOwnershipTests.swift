import Foundation
import SpeakCore
import SpeakDesktopHost
import XCTest

final class DesktopHostAPIKeyWriteOwnershipTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("api-vault-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40)
        )
        await controller.markReadyForSelfTest()
        await controller.selectVoiceOutput(.cartesia(CartesiaTTSCatalog.voices[0]))
    }

    override func tearDown() async throws {
        await controller.close()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testNativeRemoval_KeepsActorAndCloseResponsiveWithoutReleasingTheWriterEarly() async throws {
        let entered = expectation(description: "native API key removal entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.setKey("synthetic-preserved", name: "cartesia.apiKey")
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let removal = Task { await controller.removeAPIKey(identifier: "cartesia.apiKey") }
        await fulfillment(of: [entered], timeout: 3)
        removal.cancel()
        try await assertOtherEditorsRefuse()
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        XCTAssertEqual(FakeLog.shared.key("cartesia.apiKey"), "synthetic-preserved")
        let report = await controller.close()
        XCTAssertTrue(gate.isBlocked, "close waited for native vault I/O instead of its grace period")
        XCTAssertEqual(report.unfinishedOperations, 1)
        let statuses = FakeLog.shared.allStatuses
        gate.release()
        let message = await removal.value
        XCTAssertTrue(message.contains("finished after cancellation or closing"))
        XCTAssertEqual(FakeLog.shared.key("cartesia.apiKey"), "")
        let finished = await controller.activeOperations
        let owner = await controller.providerCredentialWriteTask
        XCTAssertEqual(finished, 0)
        XCTAssertNil(owner)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }

    func testCloudRemoval_KeepsTheSameWriterSlotAndSavedByHandPathUntilActualCompletion() async throws {
        let entered = expectation(description: "saved-by-hand key removal entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.setKey("synthetic-preserved", name: "cartesia.apiKey")
        FakeLog.shared.installKeyWriteHook { _, _ in XCTFail("Cloud hook bypassed for direct native write") }
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            gate.wait { entered.fulfill() }
            FakeLog.shared.setKey(value, name: identifier)
        }))
        let removal = Task { await controller.removeAPIKey(identifier: "cartesia.apiKey") }
        await fulfillment(of: [entered], timeout: 3)
        removal.cancel()
        try await assertOtherEditorsRefuse()
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        gate.release()
        let message = await removal.value
        XCTAssertTrue(message.contains("finished after cancellation or closing"))
        XCTAssertEqual(FakeLog.shared.key("cartesia.apiKey"), "")
        let finished = await controller.activeOperations
        XCTAssertEqual(finished, 0)
    }

    func testVoiceWriter_ExcludesTheAPIKeysAndPerFeatureWriters() async throws {
        let entered = expectation(description: "voice vault write entered")
        let gate = BlockingVoiceVaultGate()
        let watchdog = gate.watchdog()
        defer { watchdog.cancel(); gate.release() }
        FakeLog.shared.installKeyWriteHook { _, _ in gate.wait { entered.fulfill() } }
        let writer = Task { await controller.saveVoiceCredential(
            "synthetic-voice", purpose: "voice-output", identifier: "cartesia.apiKey"
        ) }
        await fulfillment(of: [entered], timeout: 3)
        try await assertOtherEditorsRefuse()
        gate.release()
        switch await writer.value {
        case .success: break
        case .failure(let error): XCTFail("Voice writer failed: \(error)")
        }
        XCTAssertEqual(FakeLog.shared.key("cartesia.apiKey"), "synthetic-voice")
    }

    func testUnconfirmedPartialRemoval_NeverDisclosesNativeVaultErrorContents() async throws {
        FakeLog.shared.installKeyWriteHook { _, name in
            FakeLog.shared.setKey("", name: name)
            throw DesktopHostError(message: "Sensitive native vault detail synthetic-secret")
        }
        let message = await controller.removeAPIKey(identifier: "cartesia.apiKey")
        XCTAssertTrue(message.contains("could not be confirmed"))
        XCTAssertEqual(FakeLog.shared.key("cartesia.apiKey"), "")
        XCTAssertFalse(message.contains("synthetic-secret"))
        XCTAssertFalse(FakeLog.shared.allStatuses.joined().contains("synthetic-secret"))
        let owner = await controller.providerCredentialWriteTask
        let active = await controller.activeOperations
        XCTAssertNil(owner)
        XCTAssertEqual(active, 0)
    }

    private func assertOtherEditorsRefuse() async throws {
        let retry = await controller.removeAPIKey(identifier: "cartesia.apiKey")
        XCTAssertTrue(retry.contains("Finish recording or the current Voice Output task"))
        let voice = await controller.saveVoiceCredential(
            "synthetic-retry", purpose: "voice-output", identifier: "cartesia.apiKey"
        )
        switch voice {
        case .failure(let error): XCTAssertEqual(error, .busy)
        case .success: XCTFail("A competing Voice writer was admitted")
        }
        let modelIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopHostModels.provider(for: $0.id)?.apiKeyIdentifier == "openrouter.apiKey"
        })
        await controller.saveKey("synthetic-retry", modelIndex: modelIndex)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("current provider key operation") == true)
        await controller.savePostProcessing(
            enabled: true, modelIndex: 0, prompt: "synthetic", key: "synthetic-retry"
        )
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("current provider key operation") == true)
    }
}
