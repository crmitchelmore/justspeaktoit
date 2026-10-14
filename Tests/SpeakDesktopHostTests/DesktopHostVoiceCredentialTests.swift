import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceCredentialTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-credential-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryExecutableVoice_UsesExistingCanonicalPurposeSlotAndProvider() throws {
        for voice in DesktopSpeechVoice.voices {
            let slot: VoiceOutputCredentialSlot
            do { slot = try VoiceOutputCredentialSlot(voice: voice) } catch {
                XCTFail("Unresolved canonical Voice route: \(voice.modelID), \(voice.id)")
                continue
            }
            XCTAssertEqual(slot.purpose, .voiceOutput)
            XCTAssertEqual(slot.identifier, voice.apiKeyIdentifier)
            XCTAssertFalse(slot.providerName.isEmpty)
            XCTAssertTrue(slot.privacyDescription.contains(slot.providerName))
            try slot.validate(purpose: "voice-output", identifier: voice.apiKeyIdentifier)
            XCTAssertThrowsError(try slot.validate(purpose: "batch-transcription", identifier: slot.identifier))
            XCTAssertThrowsError(try slot.validate(purpose: "voice-output", identifier: "openai.apiKey"))
        }
        let openai = try VoiceOutputCredentialSlot(voice: .openai(.mini, OpenAITTSCatalog.voices[0]))
        XCTAssertTrue(openai.entryLabel.contains("separate from transcription"))
        XCTAssertThrowsError(try openai.validatedKey(" \n "))
        XCTAssertThrowsError(try openai.validatedKey("synthetic\nkey"))
        XCTAssertThrowsError(try openai.validatedKey(String(repeating: "x", count: 8_193)))
        XCTAssertEqual(try openai.validatedKey(" synthetic-key\n"), "synthetic-key")
        let azure = try VoiceOutputCredentialSlot(voice: .azureMAI(AzureMAIVoiceCatalog.voices[0]))
        XCTAssertEqual(try azure.validatedKey("synthetic-without-region"), "synthetic-without-region")
        XCTAssertThrowsError(try azure.validatedKey("synthetic-key:https://invalid-region.example"))
        XCTAssertEqual(try azure.validatedKey("synthetic-key:eastus"), "synthetic-key:eastus")
        for model in OpenAITranscriptionModels.directBatchModelIDs {
            XCTAssertEqual(ModelCredentialResolver.requirement(for: model, purpose: .batchTranscription),
                           .apiKey(identifier: "openai.apiKey", providerName: "OpenAI"))
        }
    }

    func testSeparateOpenAISlot_SavesOnlyToVaultWithoutSettingsHistoryUsageOrOwnershipChanges() async throws {
        await selectOpenAI()
        FakeLog.shared.setKey("synthetic-transcription", name: "openai.apiKey")
        let before = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        let presentation = try await controller.voiceCredentialPresentation().get()
        XCTAssertEqual(presentation.slot.identifier, "openai.tts.apiKey")
        XCTAssertFalse(presentation.hasSavedKey)
        XCTAssertTrue(presentation.canSave)
        try await controller.saveVoiceCredential(
            " synthetic-voice-key\n", purpose: "voice-output", identifier: presentation.slot.identifier).get()
        XCTAssertEqual(FakeLog.shared.key("openai.apiKey"), "synthetic-transcription")
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-voice-key")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("settings.json")), before)
        let after = try await controller.voiceCredentialPresentation().get()
        XCTAssertTrue(after.hasSavedKey)
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let records = await controller.voiceUsage.records
        XCTAssertNil(records)
        XCTAssertFalse(FakeLog.shared.allStatuses.joined().contains("synthetic-voice-key"))
        try assertNoSecretFiles("synthetic-voice-key")
    }

    func testInvalidPurposeStaleSlotAndBlank_RefuseWithoutReplacingOrRemovingSavedKey() async throws {
        await selectOpenAI()
        FakeLog.shared.setKey("synthetic-old", name: "openai.tts.apiKey")
        let invalid = await controller.saveVoiceCredential(
            "synthetic-new", purpose: "transcription", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(invalid), .invalidPurpose)
        let foreign = await controller.saveVoiceCredential(
            "synthetic-new", purpose: "voice-output", identifier: "openai.apiKey")
        XCTAssertEqual(failure(foreign), .destinationChanged)
        let empty = await controller.saveVoiceCredential(
            " \n ", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(empty), .emptyKey)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        let stale = await controller.saveVoiceCredential(
            "synthetic-new", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(stale), .destinationChanged)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-old")
        XCTAssertEqual(FakeLog.shared.key("deepgram.apiKey"), "")
    }

    func testManualSaveAndExplicitRemoval_UseTheExistingHandMarkedHookNeverAnotherSlot() async throws {
        await selectOpenAI()
        let writes = VoiceCredentialWrites()
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            await writes.append(value, identifier)
            FakeLog.shared.setKey(value, name: identifier)
        }))
        try await controller.saveVoiceCredential(
            "synthetic-new", purpose: "voice-output", identifier: "openai.tts.apiKey").get()
        let empty = await controller.saveVoiceCredential("", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(empty), .emptyKey)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-new")
        try await controller.saveVoiceCredential(
            "", purpose: "voice-output", identifier: "openai.tts.apiKey", operation: .remove).get()
        let values = await writes.values
        XCTAssertEqual(values.map(\.0), ["synthetic-new", ""])
        XCTAssertEqual(values.map(\.1), ["openai.tts.apiKey", "openai.tts.apiKey"])
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "")
    }

    func testVaultFailure_SanitizesSecretsAndDoesNotClaimAnUnconfirmedWriteWasRolledBack() async throws {
        await selectOpenAI()
        let secret = "synthetic-partial-write"
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            FakeLog.shared.setKey(value, name: identifier)
            throw DesktopHostError(message: "Sensitive vault detail: \(value)")
        }))
        let result = await controller.saveVoiceCredential(
            secret, purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(result), .saveFailed)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), secret)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("could not be confirmed") == true)
        XCTAssertFalse(FakeLog.shared.allStatuses.joined().contains(secret))
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
        try assertNoSecretFiles(secret)
    }

    func testOutstandingSave_KeepsCapturedSlotAndRejectsConcurrentSaveWithoutChangingNewVoice() async throws {
        await selectOpenAI()
        let entered = expectation(description: "vault save entered")
        let gate = Gate(open: false)
        let writes = VoiceCredentialWrites()
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            entered.fulfill()
            await gate.pass()
            try Task.checkCancellation()
            await writes.append(value, identifier)
            FakeLog.shared.setKey(value, name: identifier)
        }))
        let active = Task { await controller.saveVoiceCredential(
            "synthetic-openai", purpose: "voice-output", identifier: "openai.tts.apiKey") }
        await fulfillment(of: [entered], timeout: 3)
        let second = await controller.saveVoiceCredential(
            "synthetic-second", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(second), .busy)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        gate.release()
        let outcome = await active.value
        XCTAssertEqual(failure(outcome), .completedForPreviousSelection)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-openai")
        XCTAssertEqual(FakeLog.shared.key("deepgram.apiKey"), "")
        let selection = await controller.voiceOutputSettings()
        XCTAssertEqual(try selection.synthesisSelection().voice, .deepgram(DeepgramSpeechCatalog.voices[0]))
        let values = await writes.values
        XCTAssertEqual(values.count, 1)
    }

    func testActiveVoiceAndClosedController_RefuseWithoutStoppingOrReassigningVoice() async throws {
        await selectOpenAI()
        let gate = Gate(open: false)
        let id = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic active.", recordID: id)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in
            await gate.pass()
            try Task.checkCancellation()
            return Data()
        }
        let active = await controller.saveVoiceCredential(
            "synthetic-refused", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(active), .busy)
        let owner = await controller.voiceOutputRecordID
        XCTAssertEqual(owner, id)
        let pending = await controller.voiceGenerationTask
        await controller.playbackStop()
        gate.release()
        await pending?.value
        await controller.close()
        let closed = await controller.saveVoiceCredential(
            "synthetic-refused", purpose: "voice-output", identifier: "openai.tts.apiKey")
        XCTAssertEqual(failure(closed), .closed)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "")
    }

}

extension DesktopHostVoiceCredentialTests {
    func testSelectionEpoch_RejectsAnOldDialogAfterVoiceChangesAwayAndBack() async throws {
        await selectOpenAI()
        let initial = try await controller.voiceCredentialPresentation().get()
        let request = try VoiceOutputCredentialRequest(
            id: UUID(), selectionEpoch: initial.selectionEpoch, purpose: "voice-output",
            identifier: initial.slot.identifier, operation: .replace)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        await selectOpenAI()
        let changed = try await controller.voiceCredentialPresentation().get()
        XCTAssertNotEqual(changed.selectionEpoch, initial.selectionEpoch)
        let result = await controller.submitVoiceCredentialForTest("synthetic-stale", request: request)
        XCTAssertEqual(failure(result), .destinationChanged)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "")
    }

    func testOwnedSave_CancelsOnlyMatchingUUIDAndDrainsBeforeCloseWithoutWriting() async throws {
        await selectOpenAI()
        let entered = expectation(description: "cancellable vault save entered")
        let gate = Gate(open: false)
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            entered.fulfill()
            await gate.pass()
            try Task.checkCancellation()
            FakeLog.shared.setKey(value, name: identifier)
        }))
        let presentation = try await controller.voiceCredentialPresentation().get()
        let request = try VoiceOutputCredentialRequest(
            id: UUID(), selectionEpoch: presentation.selectionEpoch, purpose: "voice-output",
            identifier: presentation.slot.identifier, operation: .replace)
        let task = Task { await controller.submitVoiceCredentialForTest("synthetic-cancelled", request: request) }
        await fulfillment(of: [entered], timeout: 3)
        let wrong = await controller.cancelVoiceCredentialSave(UUID())
        XCTAssertFalse(wrong)
        let outstanding = await controller.voiceCredentialRequestID
        XCTAssertEqual(outstanding, request.id)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        let cancelled = await controller.cancelVoiceCredentialSave(request.id)
        XCTAssertTrue(cancelled)
        let outcome = await task.value
        XCTAssertEqual(failure(outcome), .cancelled)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "")
    }

    func testClose_CancelsTheOwnedVaultOperationAndDoesNotPublishLateSuccess() async throws {
        await selectOpenAI()
        let entered = expectation(description: "close vault save entered")
        let gate = Gate(open: false)
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            entered.fulfill()
            await gate.pass()
            try Task.checkCancellation()
            FakeLog.shared.setKey(value, name: identifier)
        }))
        let task = Task { await controller.saveVoiceCredential(
            "synthetic-close", purpose: "voice-output", identifier: "openai.tts.apiKey") }
        await fulfillment(of: [entered], timeout: 3)
        let before = FakeLog.shared.allStatuses
        let report = await controller.close()
        let outcome = await task.value
        XCTAssertEqual(failure(outcome), .cancelled)
        XCTAssertEqual(report.unfinishedOperations, 0)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "")
        XCTAssertEqual(FakeLog.shared.allStatuses, before)
    }

    func testUncooperativeSave_ReportsConfirmedWriteAfterCancellationWithoutClaimingRollback() async throws {
        await selectOpenAI()
        let entered = expectation(description: "uncooperative vault save entered")
        let gate = VoiceCredentialUncooperativeGate()
        await controller.installCloudSync(.init(saveKeyByHand: { value, identifier in
            entered.fulfill()
            await gate.pass()
            FakeLog.shared.setKey(value, name: identifier)
        }))
        let presentation = try await controller.voiceCredentialPresentation().get()
        let request = try VoiceOutputCredentialRequest(
            id: UUID(), selectionEpoch: presentation.selectionEpoch, purpose: "voice-output",
            identifier: presentation.slot.identifier, operation: .replace)
        let task = Task { await controller.submitVoiceCredentialForTest("synthetic-confirmed", request: request) }
        await fulfillment(of: [entered], timeout: 3)
        let cancelled = await controller.cancelVoiceCredentialSave(request.id)
        XCTAssertTrue(cancelled)
        let pending = try await controller.voiceCredentialPresentation().get()
        XCTAssertFalse(pending.canSave)
        await gate.release()
        let outcome = await task.value
        XCTAssertEqual(failure(outcome), .completedWhileClosing)
        XCTAssertEqual(FakeLog.shared.key("openai.tts.apiKey"), "synthetic-confirmed")
        XCTAssertFalse(FakeLog.shared.allStatuses.joined().contains("key saved"))
        let active = await controller.activeOperations
        XCTAssertEqual(active, 0)
    }

    func testReadFailure_ReportsUnavailableWithoutDisclosingVaultDetails() async throws {
        await selectOpenAI()
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: VoiceCredentialReadFailureEffects())
        let presentation = await controller.voiceCredentialPresentation()
        if case .failure(let error) = presentation {
            XCTAssertEqual(error, .readFailed)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-vault-detail"))
        } else {
            XCTFail("Failed vault lookup was presented as a missing or saved credential")
        }
    }

    private func selectOpenAI() async {
        await controller.selectVoiceOutput(.openai(.standard, OpenAITTSCatalog.voices[0]))
    }

    private func failure(_ result: Result<Void, VoiceOutputCredentialError>) -> VoiceOutputCredentialError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private func assertNoSecretFiles(_ secret: String) throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(secret.utf8)), file.lastPathComponent)
        }
    }
}

private actor VoiceCredentialWrites {
    private(set) var values: [(String, String)] = []
    func append(_ value: String, _ identifier: String) { values.append((value, identifier)) }
}

private actor VoiceCredentialUncooperativeGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var open = false
    func pass() async {
        guard !open else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func saveVoiceCredential(
        _ key: String, purpose: String, identifier: String, operation: VoiceCredentialOperation = .replace
    ) async -> Result<Void, VoiceOutputCredentialError> {
        let request: VoiceOutputCredentialRequest
        do {
            request = try .init(id: UUID(), selectionEpoch: voiceCredentialEpoch, purpose: purpose,
                                identifier: identifier, operation: operation)
        } catch {
            return .failure(error as? VoiceOutputCredentialError ?? .unavailable)
        }
        return await submitVoiceCredentialForTest(key, request: request)
    }

    func submitVoiceCredentialForTest(
        _ key: String, request: VoiceOutputCredentialRequest
    ) async -> Result<Void, VoiceOutputCredentialError> {
        await withCheckedContinuation { continuation in
            beginVoiceCredentialSave(key, request: request) { continuation.resume(returning: $0) }
        }
    }
}

private struct VoiceCredentialReadFailureEffects: DesktopHostEffects {
    typealias Platform = FakePlatform
    let base = SyntheticEffects()
    func apiKey(name: String) throws -> String {
        throw DesktopHostError(message: "synthetic-private-vault-detail")
    }
    func makeCapture(context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int)
        throws -> any DesktopRecordingCapture {
        try base.makeCapture(context: context, deviceID: deviceID,
                             sampleRate: sampleRate, frameMilliseconds: frameMilliseconds)
    }
    func makeLiveClient(model: String, key: String, language: String?, azureEndpoint: String)
        -> (any FinalizingStreamingTranscriptionClient)? {
        base.makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }
    func transcribe(_ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>)
        async throws -> TranscriptionResult {
        try await base.transcribe(request, with: controller)
    }
    func perform(_ job: FakeJob, text: String) -> String { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}
