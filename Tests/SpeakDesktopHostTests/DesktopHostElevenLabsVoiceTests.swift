import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostElevenLabsVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("elevenlabs-voice-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        session = StubURLProtocol.makeSession()
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        FakeSpeech.shared.reset()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testPickerQualityAndFavorites_ProjectActualTuplesWithoutRewritingUnknownPreferences() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Picker/configuration accessed credentials") }
        let preset = ElevenLabsTTSCatalog.voices[0]
        let tuples = ElevenLabsTTSModels.all.map { DesktopSpeechVoice.elevenlabs($0, preset) }
        var saved = DesktopVoiceOutputSettings(voice: tuples[0])
        saved.favoriteVoices = ["future/Voice", preset.providerVoiceID, preset.providerVoiceID]
        saved.language = "en_GB"
        saved.sonioxRegion = "future-region"
        await controller.saveVoiceOutput(saved)
        for voice in tuples {
            await controller.handleVoicePicker(voiceID: voice.pickerIdentifier, action: 0)
            let chosen = await controller.voiceOutputSettings()
            XCTAssertEqual(try chosen.synthesisSelection().voice, voice)
            XCTAssertEqual(chosen.quality, voice.defaultQuality.rawValue)
            XCTAssertEqual(chosen.language, saved.language)
            XCTAssertEqual(chosen.sonioxRegion, saved.sonioxRegion)
            XCTAssertEqual(chosen.favoriteVoices, saved.favoriteVoices)
            let shown = chosen.favoritePicker(accountInventory: nil)
            XCTAssertEqual(shown.identifiers[shown.selected], voice.pickerIdentifier)
            XCTAssertEqual(shown.labels[shown.selected], voice.label)
            let indices = try tuples.map { try XCTUnwrap(shown.identifiers.firstIndex(of: $0.pickerIdentifier)) }
            XCTAssertEqual(Set(indices.map { shown.favoriteRanks[$0] }).count, 4)
            XCTAssertTrue(indices.allSatisfy { shown.favoriteRanks[$0] >= 0 })
            XCTAssertEqual(chosen.controlsPresentation.capabilities, 0)
            XCTAssertFalse(chosen.controlsPresentation.markupHelperEnabled)
        }
        await controller.handleVoicePicker(voiceID: tuples[0].pickerIdentifier, action: 2)
        let removed = await controller.voiceOutputSettings()
        XCTAssertEqual(removed.favoriteVoices, ["future/Voice"])
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testQualityMapsCanonicalModelsButUnrelatedSaveAndRestartPreserveExplicitV3() async throws {
        let preset = ElevenLabsTTSCatalog.voices[0]
        for quality in VoiceSynthesisQuality.allCases {
            let original = DesktopSpeechVoice.elevenlabs(ElevenLabsTTSModels.multilingualV2, preset)
            let effective = try original.applyingQuality(quality)
            XCTAssertEqual(effective, .elevenlabs(ElevenLabsTTSModels.model(for: quality), preset))
            XCTAssertEqual(try VoiceOutputCredentialSlot(voice: effective),
                           try VoiceOutputCredentialSlot(voice: original))
            XCTAssertEqual(effective.sampleRate(quality: quality), 24_000)
        }
        let explicit = DesktopSpeechVoice.elevenlabs(ElevenLabsTTSModels.elevenV3, preset)
        await controller.selectVoiceOutput(explicit)
        let editor = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertFalse(editor.qualityEnabled)
        XCTAssertTrue(editor.qualityTitle.contains("fixed format"))
        try await controller.saveConfiguration(editor.preferences.entries)
        for quality in VoiceSynthesisQuality.allCases {
            let accepted = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(quality: quality))
            XCTAssertTrue(accepted)
            let retained = try await controller.currentVoiceSelection()
            XCTAssertEqual(retained.voice, explicit)
        }
        let before = await controller.voiceOutputSettings()
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, before)
        XCTAssertEqual(try restored.synthesisSelection().voice, explicit)
    }

    // existing owned test covering sequential voice/provider churn; no behavior change.
    // swiftlint:disable:next function_body_length
    func testCanonicalCredentialAndCapturedGeneration_SurviveLaterVoiceAndProviderChanges() async throws {
        let original = DesktopSpeechVoice.elevenlabs(ElevenLabsTTSModels.elevenV4, ElevenLabsTTSCatalog.voices[0])
        await controller.selectVoiceOutput(original)
        let presentation = try await controller.voiceCredentialPresentation().get()
        XCTAssertEqual(presentation.slot.identifier, "elevenlabs.apiKey")
        try await controller.saveVoiceCredential(
            "synthetic-eleven", purpose: "voice-output", identifier: presentation.slot.identifier).get()
        FakeLog.shared.installKeyReadHook { name in XCTAssertEqual(name, "elevenlabs.apiKey") }
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic immutable Eleven.")
        let entered = expectation(description: "Captured Eleven selection")
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { snapshot, selection, credential in
            entered.fulfill()
            for await _ in stream { break }
            return try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await fulfillment(of: [entered], timeout: 3)
        await controller.selectVoiceOutput(.openai(.mini, OpenAITTSCatalog.voices[0]))
        continuation.yield(())
        continuation.finish()
        await controller.voiceGenerationTask?.value
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.voice, original)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.audio.wav, wav)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/text-to-dialogue")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic-eleven")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model_id"] as? String, ElevenLabsTTSModels.elevenV4.id)
        let inputs = try XCTUnwrap(body["inputs"] as? [[String: String]])
        XCTAssertEqual(inputs, [["text": source.text, "voice_id": ElevenLabsTTSCatalog.voices[0].id]])
        let usageBeforeReplay = await controller.voiceUsage.records
        let usage = try XCTUnwrap(usageBeforeReplay?.first)
        XCTAssertEqual(usageBeforeReplay?.count, 1)
        XCTAssertEqual(usage.modelID, original.modelID)
        XCTAssertEqual(usage.voiceID, original.id)
        XCTAssertEqual(usage.operation, .generate)
        XCTAssertEqual(usage.outcome, .completed)
        XCTAssertNil(usage.historyRecordID)
        XCTAssertEqual(usage.audioDuration, result.audio.duration)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Retained playback/export read a key") }
        await controller.playGeneratedVoice(result.id.uuidString)
        await controller.voiceGenerationTask?.value
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let protectedExport = directory.appendingPathComponent("synthetic-eleven.wav")
        await controller.exportGeneratedVoice(result.id.uuidString, path: protectedExport.path)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Choose an export location outside the app's data folder.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: protectedExport.path))
        let export = directory.deletingLastPathComponent()
            .appendingPathComponent("synthetic-eleven-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: export) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: export.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(FakeLog.shared.allStatuses.last,
                       "Retained voice audio exported as WAV; no synthesis request was sent.")
        XCTAssertEqual(try Data(contentsOf: export), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let usageAfterExport = await controller.voiceUsage.records
        XCTAssertEqual(usageAfterExport, usageBeforeReplay)
        let retained = await controller.generatedVoice
        XCTAssertEqual(retained?.id, result.id)
        XCTAssertEqual(retained?.audio.wav, wav)
        let records = try await controller.store.records()
        XCTAssertTrue(records.isEmpty)
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains(ElevenLabsTTSAPI.pricingEstimateBasis))
        let stale = await controller.saveVoiceCredential(
            "synthetic-wrong", purpose: "voice-output", identifier: "elevenlabs.apiKey")
        XCTAssertThrowsError(try stale.get())
        FakeLog.shared.installKeyReadHook { name in XCTAssertEqual(name, "elevenlabs.apiKey") }
        XCTAssertEqual(FakeLog.shared.key("elevenlabs.apiKey"), "synthetic-eleven")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("VoiceGeneratedPlayback").path)
        XCTAssertTrue(files.isEmpty)
    }

    func testRead_UsesGenericNativePlaybackAndLeavesOnlyTheSelectedCanonicalCredential() async throws {
        let voice = DesktopSpeechVoice.elevenlabs(ElevenLabsTTSModels.multilingualV2, ElevenLabsTTSCatalog.voices[0])
        await controller.selectVoiceOutput(voice)
        FakeLog.shared.setKey("synthetic-eleven", name: voice.apiKeyIdentifier)
        FakeLog.shared.installKeyReadHook { name in XCTAssertEqual(name, "elevenlabs.apiKey") }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic explicit snapshot.")
        await controller.readVoiceSource(source)
        await controller.readAloudState.task?.value
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Finished reading aloud.")
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("VoiceGeneratedPlayback").path)
        XCTAssertTrue(files.isEmpty)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testUnknownQualityAndFavorites_RoundTripWithoutCredentialReadsOrProviderFallback() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Unsupported settings accessed credentials") }
        var saved = DesktopVoiceOutputSettings(
            voice: .elevenlabs(ElevenLabsTTSModels.multilingualV2, ElevenLabsTTSCatalog.voices[0]))
        saved.quality = "future-quality"
        saved.favoriteVoices = ["elevenlabs/UnknownCaseSensitiveVoice", "future/Voice"]
        saved.language = "future_LANGUAGE"
        saved.sonioxRegion = "future-region"
        await controller.saveVoiceOutput(saved)
        let before = await controller.voiceOutputSettings()
        XCTAssertEqual(before, saved)
        XCTAssertThrowsError(try before.synthesisSelection()) {
            XCTAssertEqual($0 as? VoiceSynthesisConfigurationError, .unsupportedQuality)
        }
        let editor = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(editor.qualityEnabled)
        XCTAssertTrue(editor.qualityTitle.contains("unavailable"))
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, saved)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testUsageOptOut_RetainsPriorLedgerAndDoesNotInventTokenMetadata() async throws {
        let voice = DesktopSpeechVoice.elevenlabs(ElevenLabsTTSModels.multilingualV2, ElevenLabsTTSCatalog.voices[0])
        await controller.selectVoiceOutput(voice)
        FakeLog.shared.setKey("synthetic-eleven", name: voice.apiKeyIdentifier)
        await controller.saveVoiceUsageTracking(false, requestID: "synthetic-off")
        let before = await controller.voiceUsage.records
        let transport = try XCTUnwrap(session)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic opt-out.")
        await controller.generateVoiceSource(
            source,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await controller.voiceGenerationTask?.value
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, before)
        let result = await controller.generatedVoice
        XCTAssertEqual(result?.audio.wav, wav)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.trackUsage, false)
    }
}
