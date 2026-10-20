import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostSonioxOwnershipTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!
    private var context: VoiceAccountCredentialContext!
    private var inventory: VoiceAccountInventory!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("soniox-ownership-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        session = StubURLProtocol.makeSession()
        context = .init(provider: .soniox, sessionID: UUID(), epoch: UUID())
        let voice = try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first)
        var saved = DesktopVoiceOutputSettings(voice: voice)
        saved.sonioxRegion = "eu"
        await controller.saveVoiceOutput(saved)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        let payload = Data((
            #"{"voices":[{"id":"synthetic-clone","name":"Synthetic clone","models":["# +
            #"{"model":"tts-rt-v2","status":"ready"}]}]}"#).utf8)
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: nil)), payload)
        }
        inventory = try await .fetch(provider: .soniox, session: session, context: context, sonioxRegion: .europe) {
            "synthetic-key"
        }
        await controller.openModernVoiceDiscovery(context.sessionID)
        await controller.selectVoiceAccountProvider(context)
        let inventory = try XCTUnwrap(inventory)
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in inventory }
        let listing = await controller.voiceDiscovery.task
        await listing?.value
        await controller.chooseVoiceAccountVoice("soniox/synthetic-clone", epoch: context.epoch.uuidString)
        let picking = await controller.voiceDiscovery.task
        await picking?.value
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        FakeSpeech.shared.reset()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testProviderChange_CancelsRegionalCloneReadAndBalancesOwnership() async throws {
        try await assertCancellation(.provider)
    }

    func testCredentialContextChange_CancelsOldReadWithoutStaleFinish() async throws {
        try await assertCancellation(.credential)
    }

    func testRegionChange_RetiresOldFormsAndCancelsOwnedSpeech() async throws {
        try await assertCancellation(.region)
    }

    func testClose_KeepsHeldReadCountedUntilItsWorkerActuallySettles() async throws {
        try await assertCancellation(.close)
    }

    func testRegionChange_CancelsCapturedSonioxAfterStoredProviderChanges() async throws {
        try await assertBuiltInRegionChange(soniox: true)
    }

    func testRegionChange_PreservesUnrelatedActiveProviderSpeech() async throws {
        try await assertBuiltInRegionChange(soniox: false)
    }

    func testHeldCredentialIO_LeavesHostResponsiveAndCannotPlayAfterProviderChange() async throws {
        let entered = expectation(description: "synthetic regional key read held")
        let responsive = expectation(description: "host responds during held key I/O")
        let gate = RecordingWriteGate()
        defer { gate.release() }
        FakeLog.shared.installKeyReadHook { _ in
            entered.fulfill()
            do { try gate.pass(timeout: 4) } catch { XCTFail("Synthetic key gate failed: \(error)") }
        }
        await controller.readVoiceSource(try .init(source: .clipboard, text: "Synthetic held regional key."))
        await fulfillment(of: [entered], timeout: 3)
        let controller = try XCTUnwrap(controller)
        let response = Task {
            let pending = await controller.readAloudState.task
            responsive.fulfill()
            return pending
        }
        await fulfillment(of: [responsive], timeout: 1)
        let pending = await response.value
        let task = try XCTUnwrap(pending)
        await controller.selectVoiceAccountProvider(.init(
            provider: .xai, sessionID: context.sessionID, epoch: UUID()))
        XCTAssertTrue(task.isCancelled)
        gate.release()
        await task.value
        await assertWorkers(0)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "end"])
    }

    func testLateRegionalListing_CannotReplaceInventoryAfterConfigurationChanges() async throws {
        let entered = expectation(description: "synthetic old-region listing held")
        let gate = RecordingWriteGate()
        defer { gate.release() }
        let inventory = try XCTUnwrap(inventory)
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in
            entered.fulfill()
            try await Task.detached { try gate.pass(timeout: 4) }.value
            return inventory
        }
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceDiscovery.task
        let task = try XCTUnwrap(pending)
        var saved = await controller.voiceOutputSettings()
        saved.sonioxRegion = "jp"
        await controller.saveVoiceOutput(saved)
        XCTAssertTrue(task.isCancelled)
        gate.release()
        await task.value
        let discovery = await controller.voiceDiscovery
        XCTAssertNil(discovery.context)
        XCTAssertNil(discovery.inventories[.soniox])
        XCTAssertNil(discovery.listing)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    func testIssuedRegionalCredentialForm_CannotWriteAfterRegionChanges() async throws {
        let form = try await controller.voiceProviderCredentialPresentation(context).get()
        XCTAssertEqual(form.slot.identifier, VoiceOutputProvider.soniox.apiKeyIdentifier)
        let request = try VoiceProviderCredentialRequest(
            context: context, id: UUID(), purpose: "voice-output",
            identifier: form.slot.identifier, operation: .replace)
        var changed = await controller.voiceOutputSettings()
        changed.sonioxRegion = "jp"
        await controller.saveVoiceOutput(changed)
        let result = await controller.submitSonioxKey("synthetic-different-regional-key", request: request)
        do { try result.get(); XCTFail("Retired regional key form wrote credentials") } catch {
            XCTAssertEqual(error as? VoiceOutputCredentialError, .destinationChanged)
        }
        XCTAssertEqual(FakeLog.shared.key(form.slot.identifier), "synthetic-key")
    }

    private enum Change: Equatable { case provider, credential, region, close }

    private func assertCancellation(_ change: Change) async throws {
        let entered = expectation(description: "synthetic regional clone playback held")
        let gate = RecordingWriteGate()
        defer { gate.release() }
        let voice = try XCTUnwrap(inventory.desktopVoices.first)
        let probe = SonioxOwnershipPlaybackProbe(voice: voice, gate: gate, entered: entered)
        FakeSpeech.shared.setPlaybackHook { try await probe.play() }
        await controller.readVoiceSource(try .init(source: .typedText, text: "Synthetic regional clone read."))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.readAloudState.task
        let task = try XCTUnwrap(pending)
        await assertWorkers(1)
        switch change {
        case .provider, .credential:
            await controller.selectVoiceAccountProvider(.init(
                provider: change == .provider ? .xai : .soniox, sessionID: context.sessionID, epoch: UUID()))
        case .region:
            var changed = await controller.voiceOutputSettings()
            changed.sonioxRegion = "jp"
            await controller.saveVoiceOutput(changed)
        case .close:
            let report = await controller.close()
            XCTAssertEqual(report.unfinishedOperations, 1)
        }
        XCTAssertTrue(task.isCancelled)
        await assertWorkers(1)
        let statuses = FakeLog.shared.allStatuses
        gate.release()
        await task.value
        await assertWorkers(0)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.count, 1)
        XCTAssertEqual(usage?.first?.outcome, .cancelled)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }

    private func assertBuiltInRegionChange(soniox: Bool) async throws {
        let deepgram = DesktopSpeechVoice.deepgram(
            DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: nil).voice)
        let voice: DesktopSpeechVoice = soniox
            ? try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first)
            : deepgram
        var saved = DesktopVoiceOutputSettings(voice: voice)
        saved.sonioxRegion = "eu"
        await controller.saveVoiceOutput(saved)
        let entered = expectation(description: "synthetic captured-provider speech held")
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        let gate = RecordingWriteGate()
        defer { gate.release() }
        let probe = SonioxOwnershipPlaybackProbe(voice: voice, gate: gate, entered: entered)
        FakeSpeech.shared.setPlaybackHook { try await probe.play() }
        await controller.readVoiceSource(try .init(source: .typedText, text: "Synthetic captured provider."))
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.readAloudState.task
        let task = try XCTUnwrap(pending)
        if soniox {
            saved.modelID = deepgram.modelID
            saved.voiceID = deepgram.id
            await controller.saveVoiceOutput(saved)
            XCTAssertFalse(task.isCancelled)
        }
        saved.sonioxRegion = "jp"
        await controller.saveVoiceOutput(saved)
        XCTAssertEqual(task.isCancelled, soniox)
        gate.release()
        await task.value
        await assertWorkers(0)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.map(\.outcome), [soniox ? .cancelled : .completed])
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
    }

    private func assertWorkers(_ count: Int) async {
        let workers = await controller.voiceAccountWorkers
        let synthesis = await controller.voiceSynthesisWorkers
        let operations = await controller.activeOperations
        XCTAssertEqual(workers, count)
        XCTAssertEqual(synthesis, count)
        XCTAssertEqual(operations, count)
    }
}

private extension DesktopHostController where Platform == FakePlatform {
    func submitSonioxKey(
        _ key: String, request: VoiceProviderCredentialRequest
    ) async -> Result<Void, VoiceOutputCredentialError> {
        await withCheckedContinuation { continuation in
            beginVoiceProviderCredentialSave(key, request: request) { continuation.resume(returning: $0) }
        }
    }
}

private actor SonioxOwnershipPlaybackProbe {
    let voice: DesktopSpeechVoice
    let gate: RecordingWriteGate
    let entered: XCTestExpectation

    init(voice: DesktopSpeechVoice, gate: RecordingWriteGate, entered: XCTestExpectation) {
        self.voice = voice
        self.gate = gate
        self.entered = entered
    }

    func play() async throws {
        let capture = VoiceSynthesisUsage.capture
        let request = capture?.begin(voice: voice, inputCharacters: 1, usesSSML: false)
        var outcome = VoiceSynthesisUsage.Outcome.failed
        defer { if let request { capture?.finish(request, outcome: outcome) } }
        entered.fulfill()
        let gate = gate
        try await Task.detached { try gate.pass(timeout: 4) }.value
        outcome = Task.isCancelled ? .cancelled : .completed
    }
}
