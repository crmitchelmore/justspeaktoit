import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostKeywordDeliveryTests: XCTestCase {
    func testRecordingSnapshotImportRetryAndExplicitClearReachTheRealHostRequest() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        try await saveWords("Before", controller: controller)
        let captured = await controller.resolvedProfile(executablePath: nil)
        let model = captured.modelIdentifier
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Lexicon", "Canonical", "Lexicon", "automatic", "", "high", ""
        ]))
        try await saveWords("After", controller: controller)
        try await controller.startRecording(
            target: nil, deviceID: "", profile: captured, textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        XCTAssertEqual(effects.requests.first?.keywords, ["Before", "Canonical"])
        XCTAssertEqual(effects.requests.first?.language, captured.language)
        let store = controller.store
        let records = try await store.records()
        let record = try XCTUnwrap(records.first)
        let audio = try await store.audioURL(for: record)
        await controller.importAudio(path: audio.path, modelIndex: index)
        XCTAssertEqual(effects.requests.last?.keywords, ["After", "Canonical"])
        try await saveWords("", controller: controller)
        await controller.retryHistory(record.id.uuidString)
        XCTAssertEqual(effects.requests.last?.keywords, ["Canonical"])
        let retried = try await store.record(id: record.id)
        XCTAssertEqual(retried.originalText, "Synthetic transcript")
        XCTAssertEqual(effects.requests.count, 3)
        await controller.close()
    }

    func testCapturedLiveOptionsReachEffectsEvenAfterConfigurationChanges() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        try await saveWords("Captured", controller: controller)
        let profile = await controller.resolvedProfile(executablePath: nil)
        try await saveWords("New configuration", controller: controller)
        _ = try await controller.makeLiveSession(
            model: XAISpeechToText.liveCatalogID, key: "synthetic", id: UUID(),
            options: profile.transcriptionOptions
        )
        XCTAssertEqual(effects.options.last?.keywords, ["Captured"])
        XCTAssertEqual(effects.options.last?.assemblyAIKeyterms, ["Captured"])
        await controller.close()
    }

    func testUnsupportedRouteNoticeIsRetainedThenRemovedOnAnExplicitClearRetry() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let model = CartesiaBatchClient.catalogID
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let audio = root.appendingPathComponent("synthetic.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        try await saveWords("Global", controller: controller)
        await controller.importAudio(path: audio.path, modelIndex: index)
        let store = controller.store
        let records = try await store.records()
        let record = try XCTUnwrap(records.first)
        let notice = try XCTUnwrap(DesktopTranscription.keywordLimitation(model: model))
        XCTAssertTrue(record.profileNotes?.contains(notice) == true)
        try await saveWords("", controller: controller)
        await controller.retryHistory(record.id.uuidString)
        let retried = try await store.record(id: record.id)
        XCTAssertFalse(retried.profileNotes?.contains(notice) == true)
        XCTAssertEqual(effects.requests.last?.keywords, [])
        await controller.close()
    }

    func testAssemblyBatchSnapshotHonorsIndependentOverrideAndExplicitEmpty() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        let model = try XCTUnwrap(DesktopTranscription.batchModels.first { $0.id.hasPrefix("assemblyai/") }).id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let audio = root.appendingPathComponent("History/fixture.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        for words in [["Explicit"], []] {
            let record = DesktopRecordingStore.Record(
                id: UUID(), audioFilename: audio.lastPathComponent, modelIdentifier: model
            )
            let profile = DesktopProfileSession.defaults(modelIdentifier: model, postProcessing: .init())
                .capturingTranscriptionOptions(.init(keywords: ["Global"], assemblyAIKeyterms: words))
            await controller.transcribe(record, duration: 1, output: nil, profile: profile)
            XCTAssertEqual(effects.requests.last?.keywords, words)
        }
        await controller.close()
    }

    func testLegacyPronunciationHints_ReachCapturedLiveAndCompletedHostRequests() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
        let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue
        let transfer = root.appendingPathComponent("legacy-pronunciation-transfer.json")
        let vocabulary = try await controller.vocabularyStore()
        let originalEntries = await vocabulary.entries
        let expected = AssemblyAIPronunciationKeyterms.merged(
            current: ["Before"],
            seeds: AssemblyAIPronunciationKeyterms.seeds(
                modern: originalEntries.filter { !$0.isRegex }.map(\.word), legacy: ["Alpha", "Beta"]
            ), ignored: ["beta"]
        )
        let first = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Before")),
            dictionaryKey: AnyCodable(.object(["Alpha": .string("not sent"), "Beta": .string("not sent")])),
            ignoredKey: AnyCodable(.array([.string("beta")]))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: first)).write(to: transfer)
        try await controller.importConfiguration(path: transfer.path)
        let captured = await controller.resolvedProfile(executablePath: nil)
        let options = try XCTUnwrap(captured.transcriptionOptions)
        let second = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("After")),
            dictionaryKey: AnyCodable(.object(["Gamma": .string("never recognition text")]))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: second)).write(to: transfer)
        try await controller.importConfiguration(path: transfer.path)
        _ = try await controller.makeLiveSession(
            model: AssemblyAIModels.universal36ProStreamingID, key: "synthetic", id: UUID(), options: options
        )
        XCTAssertEqual(effects.options.last?.assemblyAIKeyterms, expected)
        XCTAssertEqual(effects.options.last?.keywords, ["Before"])
        let model = AssemblyAIModels.universal35ProBatchID
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let audio = root.appendingPathComponent("History").appendingPathComponent("legacy-hints.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000)).write(to: audio)
        let profile = DesktopProfileSession.defaults(modelIdentifier: model, postProcessing: .init())
            .capturingTranscriptionOptions(options)
        let record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: audio.lastPathComponent, modelIdentifier: model
        )
        await controller.transcribe(record, duration: 1, output: nil, profile: profile)
        XCTAssertEqual(effects.requests.last?.keywords, expected)
        let retainedEntries = await vocabulary.entries
        XCTAssertEqual(retainedEntries, originalEntries)
        await controller.close()
    }

    func testCapturedModulateOptions_SurviveLaterPreferenceChangesAndVocabularyMerge() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        var entries = try await controller.configuration().entries
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = "1"
        }
        try await controller.saveConfiguration(entries)
        let captured = await controller.resolvedProfile(executablePath: nil)
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Lexicon", "Canonical", "Lexicon", "automatic", "", "high", ""
        ]))
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = "0"
        }
        try await controller.saveConfiguration(entries)
        _ = try await controller.makeLiveSession(
            model: "modulate/velma-2-stt-streaming", key: "synthetic", id: UUID(),
            options: captured.transcriptionOptions
        )
        XCTAssertEqual(effects.options.last?.modulate, ModulateLiveOptions(
            speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
        ))
        XCTAssertEqual(effects.options.last?.keywords, ["Canonical"])
        let current = try await controller.configuration()
        XCTAssertEqual(current.liveOptions.modulate, .none)
        await controller.close()
    }

    func testModernPronunciationSnapshot_RecordingImportRetryAndOtherProvidersKeepDistinctHints() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let configuration = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue: AnyCodable(.object([
                "Legacy": .string("Not recognition text")
            ])),
            ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue: AnyCodable(.array([.string("hidden")]))
        ])
        let transfer = root.appendingPathComponent("recognition-preferences.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: transfer)
        try await controller.importConfiguration(path: transfer.path)
        try await replacePronunciations([
            PronunciationEntry(word: "Modern", pronunciation: "Not sent", replacement: "Never sent"),
            PronunciationEntry(word: "Hidden", pronunciation: "Also not sent"),
            PronunciationEntry(word: "Regex.*", pronunciation: "Regex speech", isRegex: true)
        ], controller: controller, root: root)
        let model = AssemblyAIModels.universal35ProBatchID
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        let profile = await controller.resolvedProfile(executablePath: nil)
        try await controller.startRecording(target: nil, deviceID: "", profile: profile, textOutput: FakeTextOutput())
        try await replacePronunciations([
            PronunciationEntry(word: "Later", pronunciation: "Still not sent")
        ], controller: controller, root: root)
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        XCTAssertEqual(effects.requests.first?.keywords, ["Explicit", "Modern", "Legacy"])
        let records = try await controller.store.records()
        let record = try XCTUnwrap(records.first)
        let audio = try await controller.store.audioURL(for: record)
        await controller.importAudio(path: audio.path, modelIndex: index)
        XCTAssertEqual(effects.requests.last?.keywords, ["Explicit", "Later", "Legacy"])
        _ = try await controller.makeLiveSession(
            model: XAISpeechToText.liveCatalogID, key: "synthetic", id: UUID(), options: profile.transcriptionOptions
        )
        XCTAssertEqual(effects.options.last?.keywords, ["Explicit"])
        XCTAssertEqual(effects.options.last?.assemblyAIKeyterms, ["Explicit", "Legacy"])
        try await saveWords("", controller: controller)
        await controller.retryHistory(record.id.uuidString)
        XCTAssertEqual(effects.requests.last?.keywords, [])
        XCTAssertEqual(effects.requests.count, 3)
        let exported = root.appendingPathComponent("recognition-export.json")
        try await controller.exportConfiguration(path: exported.path)
        let restored = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: exported))
        XCTAssertEqual(restored.preferences.liveOptions.includingPronunciationWords(["Later"]).assemblyAIKeyterms, [])
        XCTAssertEqual(restored.preferences.liveOptions.keywords, [])
        await controller.close()
    }

    func testOwnedInputSnapshot_UsesCapturedWordsWithoutRereadingEditedPronunciations() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        try await replacePronunciations([
            PronunciationEntry(word: "Later", pronunciation: "Not sent")
        ], controller: controller, root: root)
        let make: (String, String, [String]) -> DesktopHostRecordingInput
            = DesktopHostRecordingInput.init(key:azureEndpoint:vocabulary:)
        var input = make("synthetic", "", ["Lexicon"])
        input.pronunciationWords = ["Captured"]
        _ = try await controller.makeLiveSession(
            model: AssemblyAIModels.universal36ProStreamingID, key: "synthetic", id: UUID(),
            options: LiveClientOptions.desktopDefaults, input: input
        )
        XCTAssertEqual(effects.options.last?.assemblyAIKeyterms, ["Captured", "Lexicon"])
        XCTAssertEqual(effects.options.last?.keywords, ["Lexicon"])
        await controller.close()
    }

    private func replacePronunciations(
        _ entries: [PronunciationEntry], controller: DesktopHostController<FakePlatform>, root: URL
    ) async throws {
        let file = root.appendingPathComponent("recognition-pronunciations.json")
        try JSONEncoder().encode(entries).write(to: file)
        _ = try await controller.vocabularyEvent(kind: 1, payload: DesktopVocabularyWire.encode(["importReplace", file.path]))
    }

    private func saveWords(
        _ words: String, controller: DesktopHostController<FakePlatform>
    ) async throws {
        var entries = try await controller.configuration().entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "transcriptionKeywords" })
        entries[index] = words
        try await controller.saveConfiguration(entries)
    }

    func testModulateBatchRecordingSnapshotImportAndRetry_UseExplicitAndLegacyFeatureSelections() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects()
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let model = "modulate/velma-2-stt-batch"
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        try await saveModulate("1", controller: controller)
        let captured = await controller.resolvedProfile(executablePath: nil)
        try await saveModulate("0", controller: controller)
        try await controller.startRecording(
            target: nil, deviceID: "", profile: captured, textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        XCTAssertEqual(effects.requests.first?.modulateFeatures, captured.modulateBatchFeatures)
        XCTAssertEqual(captured.modulateBatchFeatures, ModulateTranscriptionFeatures(
            speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
        ))
        let records = try await controller.store.records()
        let record = try XCTUnwrap(records.first)
        let audio = try await controller.store.audioURL(for: record)
        await controller.importAudio(path: audio.path, modelIndex: index)
        XCTAssertEqual(effects.requests.last?.modulateFeatures, ModulateTranscriptionFeatures(speakerDiarization: false))
        try await saveModulate("", controller: controller)
        await controller.retryHistory(record.id.uuidString)
        XCTAssertEqual(effects.requests.last?.modulateFeatures, ModulateTranscriptionFeatures())
        XCTAssertEqual(effects.requests.count, 3)
        await controller.close()
    }

    private func saveModulate(
        _ value: String, controller: DesktopHostController<FakePlatform>
    ) async throws {
        var entries = try await controller.configuration().entries
        for key in DesktopConfiguration.modulatePreferenceKeys {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = value
        }
        try await controller.saveConfiguration(entries)
    }

    func testLiveLexiconOnlyNoticesFollowTheEffectiveRunThroughRecordingAndHistory() async throws {
        DesktopHostModels.configure(streamingQualified: true)
        let whisper = "openai/gpt-realtime-whisper-streaming"
        let cartesia = try XCTUnwrap(DesktopLiveTranscription.liveModels.first {
            DesktopLiveTranscription.route(forID: $0.id)?.provider == .cartesia
        }).id
        for model in [whisper, cartesia, XAISpeechToText.liveCatalogID] {
            try await assertLiveNotice(model: model, lexicon: true)
        }
        for model in [whisper, cartesia] {
            try await assertLiveNotice(model: model, lexicon: false)
        }
    }

    private func assertLiveNotice(model: String, lexicon: Bool) async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = KeywordDeliveryEffects(liveClient: KeywordLiveClient())
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        let selected = await controller.selectModel(index)
        XCTAssertTrue(selected)
        let profile = await controller.resolvedProfile(executablePath: nil)
            .capturingTranscriptionOptions(.init(keywords: [], assemblyAIKeyterms: ["Explicit"]))
        if lexicon {
            _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
                "save", "", "Lexicon", "Canonical", "Lexicon", "automatic", "", "high", ""
            ]))
        }
        try await saveWords("Later configuration", controller: controller)
        try await controller.startRecording(
            target: nil, deviceID: "", profile: profile, textOutput: FakeTextOutput()
        )
        let words = lexicon ? ["Canonical"] : []
        let notice = words.isEmpty ? nil : DesktopTranscription.keywordLimitation(model: model)
        let live = await controller.recording?.live
        XCTAssertNotNil(live)
        XCTAssertEqual(live?.keywordLimitation, notice)
        XCTAssertEqual(effects.options.last?.keywords, words)
        XCTAssertEqual(effects.options.last?.assemblyAIKeyterms, ["Explicit"] + words)
        let status = try XCTUnwrap(FakeLog.shared.allStatuses.last { $0.hasPrefix("Recording") })
        XCTAssertEqual(status.contains("Shared keywords are not sent"), notice != nil)
        if let notice { XCTAssertTrue(status.contains(notice)) }
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let store = try DesktopRecordingStore(directory: root.appendingPathComponent("History"))
        let records = try await store.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, live?.id)
        XCTAssertEqual(record.result?.text, "Synthetic live transcript")
        XCTAssertNil(record.failure)
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertEqual(
            record.profileNotes?.filter { $0.hasPrefix("Shared keywords are not sent") } ?? [],
            notice.map { [$0] } ?? []
        )
        await controller.close()
    }
}

private final class KeywordDeliveryEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var capturedRequests: [DesktopHostTranscriptionRequest] = []
    private var capturedOptions: [LiveClientOptions] = []
    private let liveClient: (any FinalizingStreamingTranscriptionClient)?
    var requests: [DesktopHostTranscriptionRequest] { lock.withLock { capturedRequests } }
    var options: [LiveClientOptions] { lock.withLock { capturedOptions } }

    init(liveClient: (any FinalizingStreamingTranscriptionClient)? = nil) {
        self.liveClient = liveClient
    }

    func apiKey(name: String) throws -> String { try base.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try base.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        lock.withLock { capturedOptions.append(options) }
        return liveClient
    }

    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        lock.withLock { capturedRequests.append(request) }
        return try await base.transcribe(request, with: controller)
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

private final class KeywordLiveClient: FinalizingStreamingTranscriptionClient, Sendable {
    let finalShape = TranscriptFinalShape.cumulativeTranscript
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        onTranscript("Synthetic live transcript", true)
    }
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? { "Synthetic live transcript" }
}
