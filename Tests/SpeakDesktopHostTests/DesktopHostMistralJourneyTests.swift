import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostMistralJourneyTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!
    private var context: VoiceAccountCredentialContext!
    private var inventory: VoiceAccountInventory!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mistral-journey-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(40))
        await controller.markReadyForSelfTest()
        session = StubURLProtocol.makeSession()
        context = .init(provider: .mistral, sessionID: UUID(), epoch: UUID())
        FakeLog.shared.setKey("synthetic-key", name: MistralTTSCatalog.credentialIdentifier)
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(#"[{"id":"12345678-1234-1234-1234-123456789012","name":"Synthetic voice"}]"#.utf8))
        }
        inventory = try await .mistral(.fetch(session: session, context: context, credential: { "synthetic-key" }))
        await controller.openVoiceDiscovery(context.sessionID.uuidString)
        await controller.selectVoiceAccountProvider(context)
        let inventory = try XCTUnwrap(inventory)
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in inventory }
        let listing = await controller.voiceDiscovery.task
        await listing?.value
        await controller.chooseVoiceAccountVoice(inventory.desktopVoices[0].id, epoch: context.epoch.uuidString)
        let pick = await controller.voiceDiscovery.task
        await pick?.value
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testActualOwnedSynthesis_ObservesCanonicalUsageWithIndependentRetainedExport() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic e\u{301} voice.")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        let body = try JSONEncoder().encode(["audio_data": wav.base64EncodedString()])
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)), body)
        }
        try await generate(source)
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        let records = await controller.voiceUsage.records
        let record = try XCTUnwrap(records?.last)
        XCTAssertEqual(record.modelID, MistralTTSCatalog.defaultModel.desktopModelIdentifier)
        XCTAssertEqual(record.inputCharacters, source.text.unicodeScalars.count)
        XCTAssertEqual(record.audioDuration, 0.01)
        let rate = try XCTUnwrap(Decimal(string: "0.000016"))
        XCTAssertEqual(record.estimatedCostUSD, Decimal(source.text.count) * rate)
        XCTAssertNil(record.historyRecordID)
        let requests = StubURLProtocol.recordedRequests.count
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: context.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Retained export accessed a provider key") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("mistral-retained-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: target.path)
        let exported = await controller.readAloudState.exportTask
        await exported?.value
        XCTAssertEqual(try Data(contentsOf: target), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, requests)
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
    }

    func testUnsupportedControls_RefuseBeforeAnyVaultOrSynthesisAndPreserveStoredTuple() async throws {
        let saved = await controller.voiceOutputSettings()
        let changed = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 1.25))
        XCTAssertTrue(changed)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Unsupported controls accessed the vault") }
        let count = StubURLProtocol.recordedRequests.count
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic incompatible controls.")
        await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false))
        let task = await controller.voiceGenerationTask
        XCTAssertNil(task)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        let retained = await controller.voiceOutputSettings()
        XCTAssertEqual(retained.voiceID, saved.voiceID)
        XCTAssertEqual(retained.speed, 1.25)
    }

    func testUsageOptOut_PreservesPriorMeasuredRequestsWithoutAddingNewOnes() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic opted-out voice.")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        let body = try JSONEncoder().encode(["audio_data": wav.base64EncodedString()])
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil, headerFields: nil)), body)
        }
        try await generate(source)
        let before = await controller.voiceUsage.records
        await controller.saveVoiceUsageTracking(false, requestID: "synthetic-opt-out")
        try await generate(source)
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, before)
        let generated = await controller.generatedVoice
        XCTAssertEqual(generated?.audio.wav, wav)
    }

    func testEndedAccountTicket_LateGenerationCannotCancelNewBuiltinRead() async throws {
        let gate = MistralJourneyGate()
        let entered = expectation(description: "old account synthesis owns its worker")
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic ended account ticket.")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in entered.fulfill(); await gate.wait(); return wav }
        await fulfillment(of: [entered], timeout: 3)
        let old = await controller.voiceGenerationTask
        await controller.selectVoiceOutput(.cartesia(CartesiaTTSCatalog.voices[0]))
        FakeLog.shared.setKey("synthetic-openai-key", name: OpenAITTSCatalog.credentialIdentifier)
        await controller.readVoiceSource(source)
        let newer = await controller.readAloudState.task
        XCTAssertNotNil(newer)
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: context.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        XCTAssertFalse(newer?.isCancelled == true)
        await gate.release()
        await old?.value
        await newer?.value
        let result = await controller.generatedVoice
        XCTAssertNil(result)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let remaining = await controller.activeOperations
        XCTAssertEqual(remaining, 0)
    }

    func testEndedAccountTicket_LateWorkerCannotCancelRetainedExportButControllerCloseStillCan() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic retained export ownership.")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in wav }
        let first = await controller.voiceGenerationTask
        await first?.value
        let generated = await controller.generatedVoice
        let retained = try XCTUnwrap(generated)
        let oldGate = MistralJourneyGate()
        let oldEntered = expectation(description: "old synthesis entered")
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in oldEntered.fulfill(); await oldGate.wait(); return wav }
        await fulfillment(of: [oldEntered], timeout: 3)
        let oldTask = await controller.voiceGenerationTask
        let oldTicket = await controller.voiceAccountOutputTicket
        let publicationGate = MistralJourneyGate()
        let exporting = expectation(description: "retained publication owns new ticket")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("retained-held-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        await controller.exportVoiceSource(retained.source, path: target.path, retainedAudio: retained.audio.wav,
            publish: { data, destination in
                exporting.fulfill()
                await publicationGate.wait()
                try Task.checkCancellation()
                try await DesktopVoicePlaybackFile.writeExport(data, to: destination)
            })
        await fulfillment(of: [exporting], timeout: 3)
        let export = await controller.readAloudState.exportTask
        let requests = await controller.playbackRequests
        XCTAssertFalse(requests.isCurrent(try XCTUnwrap(oldTicket)))
        let next = VoiceAccountCredentialContext(provider: .xai, sessionID: context.sessionID, epoch: UUID())
        await controller.selectVoiceAccountProvider(next)
        XCTAssertFalse(export?.isCancelled == true)
        await oldGate.release()
        await oldTask?.value
        XCTAssertFalse(export?.isCancelled == true)
        let afterOld = await controller.generatedVoice
        XCTAssertEqual(afterOld?.id, retained.id)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        XCTAssertTrue(export?.isCancelled == true)
        await publicationGate.release()
        await export?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let remaining = await controller.activeOperations
        XCTAssertEqual(remaining, 0)
    }

    private func generate(_ source: VoiceOutputSourceSnapshot) async throws {
        let session = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: session).synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                accountInventory: selection.accountInventory, credential: credential)
        }
        let task = await controller.voiceGenerationTask
        await task?.value
    }
}

private actor MistralJourneyGate {
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
