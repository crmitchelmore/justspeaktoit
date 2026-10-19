import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

extension DesktopHostAutomationTests {
    func testRequestInitializerReference_RetainsOldArityAndDefaultHistoryBehavior() {
        let make: (URL, String, String, TimeInterval, String?, [String], String?)
            -> DesktopHostTranscriptionRequest
            = DesktopHostTranscriptionRequest.init(audio:model:key:duration:language:keywords:azureEndpoint:)
        let file = URL(fileURLWithPath: "/synthetic.wav")
        let original = make(file, "openai/whisper-1", "synthetic", 1, nil, [], nil)
        let defaults = DesktopHostTranscriptionRequest(
            audio: file, model: "openai/whisper-1", key: "synthetic", duration: 1, language: nil
        )
        XCTAssertTrue(original.historySaved)
        XCTAssertTrue(defaults.historySaved)
        XCTAssertEqual(defaults.keywords, [])
        XCTAssertNil(defaults.azureEndpoint)
        XCTAssertEqual(original.modulateFeatures, .init())
        XCTAssertEqual(defaults.modulateFeatures, .init())
    }

    func testManualProfileSnapshot_ReadOnlyUsesCanonicalModelLanguageAndKeywords() async throws {
        let fixture = AutomationFixtureEffects()
        try await use(fixture)
        let profile = DictationProfile(
            name: "Read-only profile", transcriptionModelID: "openai/whisper-1", polishEnabled: true,
            languageIdentifier: "en_GB", transcriptionRouting: .remoteBatch
        )
        try await controller.automationFixtureProfile(profile)
        try await importValues([
            "transcriptionKeywords": AnyCodable(.string("Captured, Vocabulary")),
            "speedMode": AnyCodable(.string(SpeedModeID.livePolish.rawValue)),
            ApplicationPreferenceKey.modulateSpeakerDiarization.rawValue: AnyCodable(.bool(false)),
            ApplicationPreferenceKey.modulateEmotionSignal.rawValue: AnyCodable(.bool(true))
        ])
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Lexicon", "Canonical", "Lexicon", "automatic", "", "high", ""
        ]))
        let snapshot = await controller.resolvedProfile(executablePath: nil)
        let file = directory.appendingPathComponent("profile.wav")
        let original = Data(repeating: 1, count: 128)
        try original.write(to: file)
        let result = try await controller.automationTranscribeFile(at: file)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(result.model, profile.transcriptionModelID)
        XCTAssertEqual(request.model, profile.transcriptionModelID)
        XCTAssertEqual(request.key, "synthetic-profile-key")
        XCTAssertEqual(request.language, snapshot.language)
        XCTAssertEqual(request.keywords, (snapshot.transcriptionOptions?.keywords ?? []) + ["Canonical"])
        XCTAssertEqual(request.modulateFeatures, .init(speakerDiarization: false, emotionSignal: true))
        XCTAssertEqual(request.modulateFeatures, snapshot.modulateBatchFeatures)
        XCTAssertFalse(request.historySaved)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(fixture.postProcessingCalls, 0)
        XCTAssertTrue(fixture.base.outputs.isEmpty)
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        let records = try await controller.store.records()
        XCTAssertTrue(records.isEmpty)
        let approved = await controller.settings.livePolishApproved
        XCTAssertNotEqual(approved, true)
    }

    func testReadOnlyAssemblyAIFile_MergesModernPronunciationsOnlyIntoRecognitionHints() async throws {
        let fixture = AutomationFixtureEffects()
        try await use(fixture)
        let model = AssemblyAIModels.universal35ProBatchID
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic", name: credential)
        try await controller.automationFixtureProfile(DictationProfile(
            name: "AssemblyAI file", transcriptionModelID: model, polishEnabled: false, transcriptionRouting: .remoteBatch
        ))
        try await importValues([
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue: AnyCodable(.array([.string("hidden")]))
        ])
        let pronunciationFile = directory.appendingPathComponent("pronunciations.json")
        try JSONEncoder().encode([
            PronunciationEntry(word: "Modern", pronunciation: "Not sent", replacement: "Never sent"),
            PronunciationEntry(word: "Hidden", pronunciation: "Not sent"),
            PronunciationEntry(word: "Regex.*", pronunciation: "Not sent", isRegex: true)
        ]).write(to: pronunciationFile)
        _ = try await controller.vocabularyEvent(
            kind: 1, payload: DesktopVocabularyWire.encode(["importReplace", pronunciationFile.path])
        )
        let file = directory.appendingPathComponent("input.wav")
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
        try bytes.write(to: file)
        let result = try await controller.automationTranscribeFile(at: file)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(result.model, model)
        XCTAssertEqual(request.keywords, ["Explicit", "Modern"])
        XCTAssertFalse(request.historySaved)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let history = try await controller.store.records()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(fixture.postProcessingCalls, 0)
        XCTAssertTrue(fixture.base.outputs.isEmpty)
    }

    func testNativeAdmissionFailure_IsNotReportedAsSuccessfulDictation() async throws {
        try await use(AutomationFixtureEffects(refuseCapture: true))
        let response = await AutomationCommandDispatcher.response(to: .init(command: .startDictation), host: controller)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .transcriptionFailed)
        let status = await controller.automationStatus()
        XCTAssertEqual(status.sessionActive, false)
    }

    func testReadOnlyPreparation_CancellationRemovesOnlyTransferredConversionWithoutHistoryClaim() async throws {
        let previousLocalModels = DesktopHostModels.local
        DesktopHostModels.configure(streamingQualified: false, local: DesktopLocalTranscription.options(host: .linux))
        defer { DesktopHostModels.configure(streamingQualified: false, local: previousLocalModels) }
        let input = directory.appendingPathComponent("original.mp3")
        let original = Data([1, 2, 3])
        try original.write(to: input)
        FakeLog.shared.setAudioConverter { _, output in
            let wave = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 16_000))
            try wave.write(to: output)
            withUnsafeCurrentTask { $0?.cancel() }
            return 1
        }
        let model = try XCTUnwrap(WhisperCppModels.all.first).catalogueID
        XCTAssertTrue(DesktopHostModels.isLocal(model))
        let app = controller!
        let command = Task {
            try await app.transcribePreparedAudio(
                input, model: model, key: "", duration: 1, historySaved: false
            )
        }
        do {
            _ = try await command.value
            XCTFail("Cancelled preparation continued into native inference")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: input), original)
        let conversions = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("ConvertedAudio"), includingPropertiesForKeys: nil
        )
        XCTAssertTrue(conversions.isEmpty)
        XCTAssertFalse(FakeLog.shared.allStatuses.contains { $0.contains("Your original file is saved in History") })
        let records = try await controller.store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testReadOnlyCleanupFailure_ReportsRecoveryLocationAndFailureWithoutDeletingAudio() async throws {
        let converted = directory.appendingPathComponent("owned-conversion.wav")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: converted)
        do {
            try await controller.removeConvertedAudio(
                converted, historySaved: false, failure: CancellationError(),
                remove: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
            XCTFail("Cleanup failure was reported as success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(converted.path))
            XCTAssertTrue(error.localizedDescription.contains("no History record was created"))
            XCTAssertTrue(error.localizedDescription.contains("Cleanup failed"))
        }
        XCTAssertEqual(try Data(contentsOf: converted), bytes)
    }

    func testStartStop_KeepCapturedManualProfileAfterTheDefaultAndSelectionChange() async throws {
        let fixture = AutomationFixtureEffects()
        try await use(fixture)
        let profile = DictationProfile(
            name: "Captured profile", transcriptionModelID: "openai/whisper-1", polishEnabled: false,
            languageIdentifier: "en_GB", transcriptionRouting: .remoteBatch
        )
        try await controller.automationFixtureProfile(profile)
        let captured = await controller.resolvedProfile(executablePath: nil)
        _ = try await controller.automationStartDictation()
        try await controller.automationFixtureProfile(DictationProfile(name: "Later profile"))
        let result = try await controller.automationStopDictation()
        XCTAssertEqual(result.model, profile.transcriptionModelID)
        XCTAssertEqual(fixture.requests.last?.model, profile.transcriptionModelID)
        XCTAssertEqual(fixture.requests.last?.key, "synthetic-profile-key")
        XCTAssertEqual(fixture.requests.last?.language, captured.language)
        let records = try await controller.store.records()
        let saved = try XCTUnwrap(records.first)
        XCTAssertEqual(saved.profileName, profile.name)
        XCTAssertEqual(saved.modelIdentifier, profile.transcriptionModelID)
        XCTAssertEqual(saved.languageIdentifier, captured.language)
    }

    func testStop_ReportsCanonicalPostProcessingFailureAndKeepsRecoverableAudio() async throws {
        let fixture = AutomationFixtureEffects()
        try await use(fixture)
        FakeLog.shared.setKey("synthetic", name: "openrouter.apiKey")
        try await controller.automationFixtureProfile(DictationProfile(
            name: "Failure profile", transcriptionModelID: "openai/whisper-1",
            polishEnabled: true, polishModelID: ModelCatalog.defaultFastTextModel,
            transcriptionRouting: .remoteBatch
        ))
        _ = try await controller.automationStartDictation()
        let response = await AutomationCommandDispatcher.response(to: .init(command: .stopDictation), host: controller)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .transcriptionFailed)
        XCTAssertEqual(fixture.postProcessingCalls, 1)
        let records = try await controller.store.records()
        let saved = try XCTUnwrap(records.first)
        XCTAssertNotNil(saved.result)
        XCTAssertNotNil(saved.postProcessingFailure)
        let audio = try await controller.store.audioURL(for: saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testAutoCleanAndAutomationApproval_RemainIndependentAcrossImportApplyAndRestart() async throws {
        try await importValues([
            "enableAutomationServer": AnyCodable(.bool(true)),
            "speedMode": AnyCodable(.string(SpeedModeID.livePolish.rawValue))
        ])
        var allowed = await controller.automationEnabled()
        XCTAssertFalse(allowed)
        let importedApproval = await controller.settings.livePolishApproved
        XCTAssertEqual(importedApproval, false)
        let entries = try await controller.configuration().entries
        try await controller.saveConfiguration(entries)
        allowed = await controller.automationEnabled()
        XCTAssertFalse(allowed, "Applying Auto-Clean cannot grant automation")
        try await controller.saveAutomationPreference(enabled: true)
        try await importPreference(false)
        let cleanupApproval = await controller.settings.livePolishApproved
        XCTAssertEqual(cleanupApproval, true, "Revoking automation does not revoke separate Auto-Clean approval")
        try await restart()
        allowed = await controller.automationEnabled()
        XCTAssertFalse(allowed)
        let restartedApproval = await controller.settings.livePolishApproved
        XCTAssertEqual(restartedApproval, true)
    }

    func testRetainedPreferenceCarriers_CannotTurnImportedMetadataIntoLocalApproval() async throws {
        let file = directory.appendingPathComponent("retained.json")
        try Data("""
        {"version":1,"preferences":{"enableAutomationServer":true,"automationLocalConsent":true,
         "automationEnabled":true,"retained":{"settings":{"automationLocalConsent":true},
         "configuration":{"automationLocalConsent":true,"automationEnabled":true}}}}
        """.utf8).write(to: file)
        try await controller.importConfiguration(path: file.path)
        try await restart()
        let enabled = await controller.automationEnabled()
        XCTAssertFalse(enabled)
        let desired = await controller.automationDesired
        XCTAssertTrue(desired)
        let exported = directory.appendingPathComponent("retained-export.json")
        try await controller.exportConfiguration(path: exported.path)
        let document = try JSONDecoder().decode(
            DesktopConfigurationDocument.self, from: Data(contentsOf: exported)
        )
        XCTAssertNil(document.preferences.values["automationLocalConsent"])
        XCTAssertNil(document.preferences.values["automationEnabled"])
        XCTAssertNotNil(document.preferences.values["retained"], "Opaque provenance is retained, never executed")
    }

    func testFalseImport_DuringRecordingRevokesAccessBeforeRejectingOtherSettings() async throws {
        try await controller.saveAutomationPreference(enabled: true)
        _ = try await controller.automationStartDictation()
        let revoked = expectation(description: "runtime revoked during an active recording")
        await controller.setAutomationPreferenceHandler { revoked.fulfill() }
        do {
            try await importPreference(false)
            XCTFail("The remaining settings must not change during recording")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Automation access revoked"))
        }
        await fulfillment(of: [revoked], timeout: 1)
        let allowed = await controller.automationEnabled()
        XCTAssertFalse(allowed)
        let status = await controller.automationStatus()
        XCTAssertEqual(status.sessionActive, true, "Revoking control access does not discard the owned recording")
        _ = try await controller.automationStopDictation()
    }
}

extension DesktopHostController where Platform == FakePlatform {
    fileprivate func automationFixtureProfile(_ profile: DictationProfile) throws {
        if let model = profile.transcriptionModelID {
            FakeLog.shared.setKey("synthetic-profile-key", name: try credentialIdentifier(for: model))
        }
        profiles = [profile]
        manualProfileID = profile.id
        settings.model = "openai/gpt-4o-mini-transcribe"
    }
}

final class AutomationFixtureEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let base = SyntheticEffects()
    private let lock = NSLock()
    private var captured: [DesktopHostTranscriptionRequest] = []
    private var postCalls = 0
    private let gate: AutomationCommandGate?
    private let refuseCapture: Bool
    private let onEnter: @Sendable () -> Void
    var requests: [DesktopHostTranscriptionRequest] { lock.withLock { captured } }
    var postProcessingCalls: Int { lock.withLock { postCalls } }

    init(blocking: Bool = false, refuseCapture: Bool = false, onEnter: @escaping @Sendable () -> Void = {}) {
        gate = blocking ? AutomationCommandGate() : nil
        self.refuseCapture = refuseCapture
        self.onEnter = onEnter
    }

    func apiKey(name: String) throws -> String { try base.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        if refuseCapture { throw DesktopHostError(message: "Synthetic capture admission failure") }
        return try base.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        lock.withLock { captured.append(request) }
        onEnter()
        await gate?.wait()
        try Task.checkCancellation()
        return try await base.transcribe(request, with: controller)
    }
    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        lock.withLock { postCalls += 1 }
        throw DesktopHostError(message: "Read-only transcription invoked post-processing")
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

private final class AutomationCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completed = lock.withLock {
                    if ended { return true }
                    waiter = continuation
                    return false
                }
                if completed { continuation.resume() }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            ended = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}
