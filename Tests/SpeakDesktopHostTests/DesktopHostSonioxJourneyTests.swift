import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostSonioxJourneyTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!
    private var context: VoiceAccountCredentialContext!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("soniox-journey-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        session = StubURLProtocol.makeSession()
        context = .init(provider: .soniox, sessionID: UUID(), epoch: UUID())
        var saved = DesktopVoiceOutputSettings()
        saved.sonioxRegion = "jp"
        saved.language = "fr_FR"
        saved.favoriteVoices = ["soniox/synthetic-clone", "soniox/deleted-clone"]
        await controller.saveVoiceOutput(saved)
        FakeLog.shared.setKey("synthetic-key", name: VoiceOutputProvider.soniox.apiKeyIdentifier)
        let page = Data((
            #"{"voices":[{"id":"synthetic-clone","name":"Synthetic clone","models":["# +
            #"{"model":"tts-rt-v2","status":"ready"}]}]}"#).utf8)
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap($0.url), statusCode: 200,
                httpVersion: nil, headerFields: nil)), page)
        }
        let inventory = try await VoiceAccountInventory.fetch(
            provider: .soniox, session: session, context: context, sonioxRegion: .japan) { "synthetic-key" }
        await controller.openModernVoiceDiscovery(context.sessionID)
        await controller.selectVoiceAccountProvider(context)
        await controller.refreshVoiceAccountDiscovery(context.epoch.uuidString) { _, _ in inventory }
        let listing = await controller.voiceDiscovery.task
        await listing?.value
        await controller.chooseVoiceAccountVoice("soniox/synthetic-clone", epoch: context.epoch.uuidString)
        let pick = await controller.voiceDiscovery.task
        await pick?.value
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        FakeSpeech.shared.reset()
        FakeLog.shared.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testActualSharedCloneSynthesis_RetainsRegionalAudioFriendlyIdentityUsageAndIndependentExport() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cafe\u{301} clone.")
        let wav = try wave()
        respond(wav)
        try await generate(source)
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        XCTAssertEqual(result.voice.id, "soniox/synthetic-clone")
        XCTAssertEqual(result.voice.name, "Synthetic clone")
        XCTAssertTrue(result.voice.label.contains(SonioxTTSCatalog.defaultModel.displayName))
        let records = await controller.voiceUsage.records
        let record = try XCTUnwrap(records?.last)
        XCTAssertEqual(record.modelID, SonioxTTSCatalog.defaultModel.rawValue)
        XCTAssertEqual(record.voiceID, result.voice.id)
        XCTAssertEqual(record.inputCharacters, source.text.unicodeScalars.count)
        XCTAssertEqual(record.audioDuration, 0.01)
        XCTAssertEqual(record.estimatedCostUSD,
                       Decimal(source.text.count) * SonioxTTSAPI.estimatedCostPerThousandCharacters / 1_000)
        XCTAssertNil(record.historyRecordID)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
        XCTAssertEqual(request.url, SonioxTTSRegion.japan.speakEndpoint)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: StubURLProtocol.body(of: request)) as? [String: Any])
        XCTAssertEqual(body["voice"] as? String, "synthetic-clone")
        XCTAssertEqual(body["language"] as? String, "fr")
        let count = StubURLProtocol.recordedRequests.count
        await controller.selectVoiceAccountProvider(.init(provider: .xai, sessionID: context.sessionID, epoch: UUID()))
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Retained Soniox export read credentials") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("soniox-retained-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: target.path)
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertEqual(try Data(contentsOf: target), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, count)
        let workers = await controller.voiceSynthesisWorkers
        let operations = await controller.activeOperations
        XCTAssertEqual(workers, 0)
        XCTAssertEqual(operations, 0)
    }

    func testSourceExport_UsesCapturedRegionAndFailureLeavesChosenDestinationUnchanged() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("soniox-source-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let sentinel = Data("synthetic prior export".utf8)
        try sentinel.write(to: target)
        respond(Data("synthetic invalid wav".utf8))
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic source export.")
        let session = try XCTUnwrap(session)
        await controller.exportVoiceSource(source, path: target.path) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: session).synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                accountInventory: selection.accountInventory, sonioxRegion: selection.sonioxRegion,
                language: selection.language, credential: credential)
        }
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.hasPrefix("Voice export failed:") == true)
        XCTAssertEqual(StubURLProtocol.recordedRequests.last?.url, SonioxTTSRegion.japan.speakEndpoint)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.map(\.outcome), [.failed])
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    func testBuiltinGeneration_ArchivesCompleteWAVAndUsageOptOutDoesNotResynthesizeRetainedAudio() async throws {
        let voice = try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first)
        await controller.selectVoiceOutput(voice)
        let wav = try wave()
        respond(wav)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic builtin archive.")
        try await generate(source, archive: true)
        let enumeration = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil))
        let archives = enumeration.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "wav" }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), wav)
        let before = await controller.voiceUsage.records
        await controller.saveVoiceUsageTracking(false, requestID: "synthetic-soniox-opt-out")
        try await generate(source)
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, before)
        let result = await controller.generatedVoice
        XCTAssertEqual(result?.voice, voice)
        XCTAssertEqual(result?.audio.wav, wav)
    }

    func testRestart_CloneAndFavoritesRemainStoredButRequireFreshRegionalEvidence() async throws {
        let saved = await controller.voiceOutputSettings()
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored.favoriteVoices, ["soniox/synthetic-clone", "soniox/deleted-clone"])
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Unrefreshed clone read credentials") }
        do {
            _ = try await controller.currentVoiceSelection()
            XCTFail("Restart trusted persisted clone evidence")
        } catch {
            XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice)
        }
        let unchanged = await controller.voiceOutputSettings()
        XCTAssertEqual(unchanged, saved)
    }

    private func wave() throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
    }

    private func respond(_ data: Data) {
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap($0.url), statusCode: 200,
                httpVersion: nil, headerFields: nil)), data)
        }
    }

    private func generate(_ source: VoiceOutputSourceSnapshot, archive: Bool = false) async throws {
        let session = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: archive)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: session).synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                accountInventory: selection.accountInventory, sonioxRegion: selection.sonioxRegion,
                language: selection.language, credential: credential)
        }
        let task = await controller.voiceGenerationTask
        await task?.value
    }
}
