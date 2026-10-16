import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostVoicePronunciationTests: XCTestCase {
    var directory: URL!
    var controller: DesktopHostController<PronunciationVoicePlatform>!
    let voice = DesktopSpeechVoice.openai(.mini, OpenAITTSCatalog.voices[0])
    let entry = PronunciationEntry(
        word: "Token", pronunciation: "synthetic", replacement: "Token Token", caseSensitive: true)

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        VoicePronunciationProbe.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-pronunciation-\(UUID())")
        controller = try DesktopHostController(
            directory: directory, effects: VoicePronunciationEffects(), shutdownGrace: .milliseconds(30))
        await controller.markReadyForSelfTest()
        await controller.selectVoiceOutput(voice)
        FakeLog.shared.setKey("synthetic-pronunciation-key", name: voice.apiKeyIdentifier)
        FakeLog.shared.installKeyReadHook { VoicePronunciationProbe.shared.readKey($0) }
        try await saveEntries([entry], reload: false)
    }

    override func tearDown() async throws {
        await controller.close()
        StubURLProtocol.reset()
        FakeSpeech.shared.reset()
        FakeLog.shared.reset()
        VoicePronunciationProbe.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testRead_AllAvailableSourcesReachGenericProviderWithOneReplacementAndOriginalOwnership() async throws {
        let sources = try await sourcesWithHistory()
        let before = try await historyBytes()
        for source in sources {
            await controller.readVoiceSource(source)
            let pending = await controller.readAloudState.task
            await pending?.value
            let call = try XCTUnwrap(VoicePronunciationProbe.shared.calls.last)
            XCTAssertEqual(call.source.text, "Token Token")
            XCTAssertEqual(call.source.source, source.source)
            XCTAssertEqual(call.source.recordID, source.recordID)
            XCTAssertEqual(call.selection.voice, voice)
            XCTAssertEqual(source.text, "Token")
            XCTAssertEqual(FakeLog.shared.allStatuses.last, "Finished reading aloud.")
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, sources.count)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, Array(repeating: voice.apiKeyIdentifier, count: 4))
        XCTAssertEqual(FakeSpeech.shared.events, Array(repeating: ["begin", "play", "end"], count: 4).flatMap { $0 })
        let after = try await historyBytes()
        XCTAssertEqual(after, before)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.map(\.source), sources.map(\.source))
        XCTAssertEqual(usage?.map(\.historyRecordID), sources.map(\.recordID))
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testLegacyHistoryReadAndSegmentEngine_ApplyNonIdempotentDictionaryExactlyOnce() async throws {
        let sources = try await sourcesWithHistory()
        let source = try XCTUnwrap(sources.last)
        let selected = DesktopSpeechVoice.deepgram(DeepgramSpeechCatalog.voices[0])
        await controller.selectVoiceOutput(selected)
        let saved = await controller.saveVoiceSynthesisOptions(try .init(quality: .high))
        XCTAssertTrue(saved)
        FakeLog.shared.setKey("synthetic-pronunciation-key", name: selected.apiKeyIdentifier)
        let before = try await historyBytes()
        await controller.readAloud(try XCTUnwrap(source.recordID).uuidString, text: source.text)
        let pending = await controller.readAloudState.task
        await pending?.value
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), ["Token Token"])
        XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [selected.apiKeyIdentifier])
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let after = try await historyBytes()
        XCTAssertEqual(after, before)
        await assertSettled()
    }

    func testGenerate_AllSourcesKeepOriginalSnapshotAndHistoryWhileProviderGetsPreparedText() async throws {
        let sources = try await sourcesWithHistory()
        let before = try await historyBytes()
        let wav = try VoicePronunciationProbe.audio()
        for source in sources {
            await generate(source)
            let result = try await generated()
            XCTAssertEqual(result.source, source)
            XCTAssertEqual(result.audio.wav, wav)
            XCTAssertEqual(result.voice, voice)
            let call = try XCTUnwrap(VoicePronunciationProbe.shared.calls.last)
            XCTAssertEqual(call.source.text, "Token Token")
            XCTAssertEqual(call.source.source, source.source)
            XCTAssertEqual(call.source.recordID, source.recordID)
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 4)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 4)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let after = try await historyBytes()
        XCTAssertEqual(after, before)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.map(\.source), sources.map(\.source))
        XCTAssertEqual(usage?.map(\.historyRecordID), sources.map(\.recordID))
        XCTAssertEqual(usage?.map(\.inputCharacters), Array(repeating: "Token Token".unicodeScalars.count, count: 4))
        await assertSettled()
    }

    func testDirectExport_AllSourcesRenderOnceWithoutChangingHistoryOrPlayingAudio() async throws {
        let sources = try await sourcesWithHistory()
        let before = try await historyBytes()
        for source in sources {
            let destination = exportDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            await controller.exportVoiceSource(source, path: destination.path) { input, selection, credential in
                try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                    input, selection: selection, credential: credential)
            }
            let pending = await controller.readAloudState.exportTask
            await pending?.value
            XCTAssertEqual(try Data(contentsOf: destination), try VoicePronunciationProbe.audio())
            let call = try XCTUnwrap(VoicePronunciationProbe.shared.calls.last)
            XCTAssertEqual(call.source.text, "Token Token")
            XCTAssertEqual(call.source.source, source.source)
            XCTAssertEqual(call.source.recordID, source.recordID)
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 4)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 4)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let after = try await historyBytes()
        XCTAssertEqual(after, before)
        await assertSettled()
    }

    func testActualOpenAIRequest_ContainsPreparedInputAndCapturedModelNotDisplaySource() async throws {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let wav = try VoicePronunciationProbe.audio()
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Token")
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { input, selection, credential in
            try await DesktopSpeechSynthesis(session: session).synthesize(
                input, voice: selection.voice, options: selection.options, credential: credential)
        }
        let pending = await controller.voiceGenerationTask
        await pending?.value
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, "Token Token")
        XCTAssertEqual(body["model"] as? String, OpenAITTSModel.mini.rawValue)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [voice.apiKeyIdentifier])
        let result = try await generated()
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.audio.wav, wav)
    }

    func testCanonicalRegexOrderCaseAndUnicode_AreNotReimplementedByHostPreparation() async throws {
        let entries = [
            PronunciationEntry(word: "CAT", pronunciation: "x", replacement: "dog"),
            PronunciationEntry(word: "dog", pronunciation: "x", replacement: "hound", caseSensitive: true),
            PronunciationEntry(word: #"(猫)(\d+)"#, pronunciation: "x", replacement: "$2$1", isRegex: true),
            PronunciationEntry(word: "IPA", pronunciation: "aɪ piː eɪ")
        ]
        try await saveEntries(entries)
        let original = try VoiceOutputSourceSnapshot(source: .typedText, text: "Cat scatter dog 猫12 IPA")
        await generate(original)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.last?.source.text, "hound scatter hound 12猫 IPA")
        let result = try await generated()
        XCTAssertEqual(result.source, original)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 1)
    }

    func testExplicitSSML_RemainsByteExactAndDoesNotLoadOrInferDictionaryMarkup() async throws {
        let selected = DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0])
        await controller.selectVoiceOutput(selected)
        let accepted = await controller.saveVoiceSynthesisOptions(try .init(useSSML: true))
        XCTAssertTrue(accepted)
        FakeLog.shared.setKey("synthetic-pronunciation-key", name: selected.apiKeyIdentifier)
        let damaged = directory.appendingPathComponent("pronunciation.json")
        try Data("synthetic corrupt dictionary".utf8).write(to: damaged)
        await controller.installPronunciationLoad(nil)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "<speak>Token</speak>")
        await generate(source)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.last?.source, source)
        let result = try await generated()
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [selected.apiKeyIdentifier])
        XCTAssertEqual(try Data(contentsOf: damaged), Data("synthetic corrupt dictionary".utf8))
    }
}

extension DesktopHostVoicePronunciationTests {
    func saveEntries(_ entries: [PronunciationEntry], reload: Bool = true) async throws {
        try await PronunciationStore(directory: directory).save(entries)
        if reload {
            let vocabulary = try await controller.vocabularyStore()
            try await vocabulary.reload()
        }
    }

    func sourcesWithHistory() async throws -> [VoiceOutputSourceSnapshot] {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "synthetic.wav", modelIdentifier: "synthetic/model")
        record.processedText = "Token"
        try await controller.installPronunciationHistory(record)
        let kinds: [VoiceOutputSource] = [.typedText, .clipboard, .textFile, .history]
        return try kinds.map {
            try VoiceOutputSourceSnapshot(source: $0, text: "Token", recordID: record.id)
        }
    }

    func historyBytes() async throws -> [Data] {
        let records = try await controller.store.records()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try records.map { try encoder.encode($0) }
    }

    func generate(_ source: VoiceOutputSourceSnapshot) async {
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { input, selection, credential in
            try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                input, selection: selection, credential: credential)
        }
        let pending = await controller.voiceGenerationTask
        await pending?.value
    }

    func generated() async throws -> DesktopGeneratedVoiceResult {
        let retained = await controller.generatedVoice
        return try XCTUnwrap(retained)
    }

    func exportDestination() -> URL {
        directory.deletingLastPathComponent().appendingPathComponent("voice-pronunciation-\(UUID()).wav")
    }

    func assertPlaybackFilesEmpty() throws {
        let folder = directory.appendingPathComponent("VoiceGeneratedPlayback")
        if FileManager.default.fileExists(atPath: folder.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    func assertSettled() async {
        let active = await controller.activeOperations
        let synthesis = await controller.voiceSynthesisWorkers
        let account = await controller.voiceAccountWorkers
        let owner = await controller.voiceOutputRecordID
        XCTAssertEqual(active, 0)
        XCTAssertEqual(synthesis, 0)
        XCTAssertEqual(account, 0)
        XCTAssertNil(owner)
    }
}
