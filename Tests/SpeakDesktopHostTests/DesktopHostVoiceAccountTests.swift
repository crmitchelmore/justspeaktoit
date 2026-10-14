import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostVoiceAccountTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-account-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        session = StubURLProtocol.makeSession()
        FakeLog.shared.setKey("synthetic-mistral-key", name: MistralTTSCatalog.credentialIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testBootstrap_HostIssuedSlotAndOnlyPickPersistTheWholeTuple() async throws {
        let context = await open()
        let before = await controller.voiceOutputSettings()
        let request = try credentialRequest(context)
        let refused = await controller.submitAccountKey("synthetic-new-key", request: request)
        XCTAssertEqual(error(refused), .destinationChanged)
        let form = try await controller.voiceProviderCredentialPresentation(context).get()
        XCTAssertEqual(form.slot.identifier, MistralTTSCatalog.credentialIdentifier)
        XCTAssertEqual(form.selectionEpoch, context.epoch)
        try await controller.submitAccountKey("synthetic-new-key", request: request).get()
        let afterKey = await controller.voiceOutputSettings()
        XCTAssertEqual(afterKey, before)
        let inventory = try await listing(context, key: "synthetic-new-key")
        await refresh(context, inventory: inventory)
        let afterList = await controller.voiceOutputSettings()
        XCTAssertEqual(afterList, before)
        let epoch = context.epoch.uuidString.lowercased()
        await controller.chooseDiscoveredVoice(inventory.desktopVoices[0].id, requestID: context.sessionID.uuidString)
        let refusedPick = await controller.voiceOutputSettings()
        XCTAssertEqual(refusedPick, before)
        await controller.chooseDiscoveredVoice(inventory.desktopVoices[0].id, requestID: epoch)
        let pick = await controller.voiceDiscovery.task
        await pick?.value
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.modelID, MistralTTSCatalog.defaultModel.desktopModelIdentifier)
        XCTAssertEqual(saved.voiceID, inventory.desktopVoices[0].id)
        XCTAssertEqual(saved.controlsPresentation(accountInventory: inventory).capabilities, 0)
        XCTAssertFalse(
            saved.pickerPresentation(accountInventory: inventory).labels.last?.contains("Unavailable") == true)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        XCTAssertNil(bytes.range(of: Data("synthetic-new-key".utf8)))
    }

    func testChangedProvider_RejectsLateListingOldEpochAndRetaggedPickUntilWorkerSettles() async throws {
        let first = await open()
        let inventory = try await listing(first)
        let entered = expectation(description: "owned listing entered")
        let gate = AccountVoiceGate()
        await controller.refreshVoiceAccountDiscovery(first.epoch.uuidString) { _, _ in
            entered.fulfill()
            await gate.wait()
            return inventory
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceDiscovery.task
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: first.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        await controller.selectVoiceAccountProvider(first)
        let state = await controller.voiceDiscovery
        XCTAssertEqual(state.context, next)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 1)
        await controller.chooseDiscoveredVoice(inventory.desktopVoices[0].id, requestID: next.epoch.uuidString)
        await controller.refreshVoiceAccountDiscovery(first.epoch.uuidString) { _, _ in
            XCTFail("Old epoch reached listing transport")
            return inventory
        }
        await gate.release()
        await task?.value
        let settled = await controller.voiceDiscovery
        XCTAssertNil(settled.listing)
        XCTAssertNil(settled.inventories[.mistral])
        XCTAssertNil(settled.task)
        let saved = await controller.voiceOutputSettings()
        XCTAssertNil(saved.voiceID)
        let remaining = await controller.activeOperations
        XCTAssertEqual(remaining, 0)
    }

    func testCloseReopen_RejectsOldContextWithoutDestroyingPickedVoiceEvidence() async throws {
        let first = await open()
        let inventory = try await listing(first)
        await refresh(first, inventory: inventory)
        await controller.chooseVoiceAccountVoice(inventory.desktopVoices[0].id, epoch: first.epoch.uuidString)
        let pick = await controller.voiceDiscovery.task
        await pick?.value
        await controller.closeVoiceDiscovery(first.sessionID.uuidString.lowercased())
        let next = await open()
        await controller.selectVoiceAccountProvider(first)
        await controller.chooseVoiceAccountVoice(inventory.desktopVoices[0].id, epoch: next.epoch.uuidString)
        let state = await controller.voiceDiscovery
        XCTAssertEqual(state.context, next)
        XCTAssertNil(state.listing)
        XCTAssertEqual(state.inventories[.mistral], inventory)
        let current = try await controller.currentVoiceSelection()
        XCTAssertEqual(current.voice, inventory.desktopVoices[0])
        let obsolete = await controller.voiceProviderCredentialPresentation(first)
        if case .failure(let failure) = obsolete { XCTAssertEqual(failure, .destinationChanged) } else {
            XCTFail("Closed dialog issued a new credential slot")
        }
    }

    private func open() async -> VoiceAccountCredentialContext {
        let context = VoiceAccountCredentialContext(provider: .mistral, sessionID: UUID(), epoch: UUID())
        await controller.openVoiceDiscovery(context.sessionID.uuidString)
        do {
            let message = try DesktopVoiceSourceMessage(action: 118, source: -1,
                text: context.provider.id + "\n" + context.epoch.uuidString.lowercased(),
                record: context.sessionID.uuidString.lowercased(), path: "account-provider")
            await controller.handleVoiceDiscovery(message)
        } catch { XCTFail("Canonical provider transition could not be parsed: \(error)") }
        return context
    }

    private func listing(
        _ context: VoiceAccountCredentialContext, key: String = "synthetic-mistral-key"
    ) async throws -> VoiceAccountInventory {
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(#"[{"id":"12345678-1234-1234-1234-123456789012","name":"Synthetic voice"}]"#.utf8))
        }
        return try await .mistral(.fetch(session: session, context: context, credential: { key }))
    }

    private func refresh(_ context: VoiceAccountCredentialContext, inventory: VoiceAccountInventory) async {
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in inventory }
        let task = await controller.voiceDiscovery.task
        await task?.value
    }

    private func credentialRequest(_ context: VoiceAccountCredentialContext) throws -> VoiceProviderCredentialRequest {
        try .init(context: context, id: UUID(), purpose: "voice-output",
            identifier: VoiceOutputCredentialSlot(provider: context.provider).identifier, operation: .replace)
    }

    private func error(_ result: Result<Void, VoiceOutputCredentialError>) -> VoiceOutputCredentialError? {
        if case .failure(let failure) = result { return failure }
        return nil
    }
}

extension DesktopHostVoiceAccountTests {
    func testCancelledUncooperativeWrite_KeepsOwnedSlotWithoutSuccessForAnotherProvider() async throws {
        let first = await open()
        _ = try await controller.voiceProviderCredentialPresentation(first).get()
        let entered = expectation(description: "owned write entered")
        let gate = AccountVoiceGate()
        await controller.installCloudSync(.init(saveKeyByHand: { key, identifier in
            entered.fulfill()
            await gate.wait()
            FakeLog.shared.setKey(key, name: identifier)
        }))
        let request = try credentialRequest(first)
        let controller = try XCTUnwrap(controller)
        let save = Task { await controller.submitAccountKey("synthetic-late-write", request: request) }
        await fulfillment(of: [entered], timeout: 3)
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: first.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        _ = try await controller.voiceProviderCredentialPresentation(next).get()
        let nextRequest = try credentialRequest(next)
        let refused = await controller.submitAccountKey("synthetic-other-key", request: nextRequest)
        XCTAssertEqual(error(refused), .busy)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        await gate.release()
        let outcome = await save.value
        XCTAssertEqual(error(outcome), .completedWhileClosing)
        XCTAssertEqual(FakeLog.shared.key(MistralTTSCatalog.credentialIdentifier), "synthetic-late-write")
        XCTAssertEqual(FakeLog.shared.key(XAITTSCatalog.credentialIdentifier), "")
        XCTAssertFalse(FakeLog.shared.allStatuses.contains(where: { $0.contains("key saved") }))
        let after = await controller.voiceOutputSettings()
        XCTAssertNil(after.voiceID)
        let ended = await controller.activeOperations
        XCTAssertEqual(ended, 0)
    }

    func testUncooperativeGeneration_ProviderChangeKeepsOwnershipUntilSettlementButCannotPublish() async throws {
        let first = await open()
        let inventory = try await listing(first)
        await refresh(first, inventory: inventory)
        await controller.chooseVoiceAccountVoice(inventory.desktopVoices[0].id, epoch: first.epoch.uuidString)
        let pick = await controller.voiceDiscovery.task
        await pick?.value
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic fenced generation.")
        let entered = expectation(description: "synthesis entered")
        let gate = AccountVoiceGate()
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, selection, credential in
            XCTAssertEqual(selection.accountInventory, inventory)
            let key = try await credential()
            XCTAssertEqual(key, "synthetic-mistral-key")
            entered.fulfill()
            await gate.wait()
            return wav
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceGenerationTask
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: first.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        let workers = await controller.voiceAccountWorkers
        XCTAssertEqual(workers, 1)
        let form = try await controller.voiceProviderCredentialPresentation(next).get()
        XCTAssertFalse(form.canSave)
        await gate.release()
        await task?.value
        let result = await controller.generatedVoice
        XCTAssertNil(result)
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let remaining = await controller.voiceAccountWorkers
        XCTAssertEqual(remaining, 0)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.voiceID, inventory.desktopVoices[0].id)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }

    func testProviderBrowsing_PreservesUnrelatedBuiltinGenerationAndItsOwnedLookup() async throws {
        await controller.selectVoiceOutput(.openai(.standard, OpenAITTSCatalog.voices[0]))
        let first = await open()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic independent built-in voice.")
        let gate = AccountVoiceGate()
        let entered = expectation(description: "built-in synthesis entered")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in
            entered.fulfill()
            await gate.wait()
            XCTAssertFalse(Task.isCancelled)
            return wav
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceGenerationTask
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: first.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        let account = await controller.voiceAccountWorkers
        let synthesis = await controller.voiceSynthesisWorkers
        XCTAssertEqual(account, 0)
        XCTAssertEqual(synthesis, 1)
        let form = try await controller.voiceProviderCredentialPresentation(next).get()
        XCTAssertFalse(form.canSave)
        await gate.release()
        await task?.value
        let generated = await controller.generatedVoice
        XCTAssertEqual(generated?.audio.wav, wav)
        XCTAssertEqual(generated?.voice, .openai(.standard, OpenAITTSCatalog.voices[0]))
        let after = await controller.voiceSynthesisWorkers
        XCTAssertEqual(after, 0)
    }

    func testProviderChanges_DoNotCancelOwnedTextImportOrChangeTheSavedVoice() async throws {
        let first = await open()
        let gate = AccountVoiceGate()
        let entered = expectation(description: "Voice text import entered")
        let completed = expectation(description: "Voice text import still completed")
        await controller.importVoiceText(path: "/synthetic.txt", requestID: "synthetic-account-import") { _ in
            entered.fulfill()
            await gate.wait()
            return "Synthetic preserved text import."
        } completion: { result in
            if case .success(let text) = result { XCTAssertEqual(text, "Synthetic preserved text import.") } else {
                XCTFail("Provider browsing cancelled an unrelated text import")
            }
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await controller.voiceTextImportTask
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: first.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        await gate.release()
        await task?.value
        await fulfillment(of: [completed], timeout: 3)
        let saved = await controller.voiceOutputSettings()
        XCTAssertNil(saved.voiceID)
    }
}

private actor AccountVoiceGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

private extension DesktopHostController where Platform == FakePlatform {
    func submitAccountKey(
        _ key: String, request: VoiceProviderCredentialRequest
    ) async -> Result<Void, VoiceOutputCredentialError> {
        await withCheckedContinuation { continuation in
            beginVoiceProviderCredentialSave(key, request: request) { continuation.resume(returning: $0) }
        }
    }
}
