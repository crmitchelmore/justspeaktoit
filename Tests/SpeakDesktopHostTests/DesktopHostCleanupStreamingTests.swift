import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostCleanupStreamingTests: XCTestCase {
    private var directory: URL!
    private var host: DesktopHostController<FakePlatform>!
    private var effects: CleanupHostEffects!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-stream-\(UUID())")
        let outcome = try await DesktopPostProcessing.process(
            rawText: "final cleanup", options: .init(
                mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID
            ), apiKey: ""
        )
        effects = CleanupHostEffects(outcome: outcome)
        host = try DesktopHostController(directory: directory, effects: effects, shutdownGrace: .milliseconds(5))
        await host.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        effects?.release()
        if let host { await host.close() }
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testActualHostCallback_PreviewDoesNotPersistOrOutputBeforeFinal() async throws {
        let record = try await record()
        let entered = expectation(description: "entered real Host streaming effect")
        effects.entered = { entered.fulfill() }
        let host = host!
        let options = options()
        let task = Task { await host.postProcess(record, options: options) }
        await fulfillment(of: [entered], timeout: 2)
        let activeID = await host.postProcessingID
        let requestID = try XCTUnwrap(activeID)
        let presentation = await host.cleanupPresentationEpoch
        effects.emit("uncommitted partial")
        try await waitForPreview("uncommitted partial")
        let saved = try await host.store.record(id: record.id)
        XCTAssertEqual(saved.result?.text, "raw provider")
        XCTAssertNil(saved.processedText)
        XCTAssertNil(saved.postProcessingModelIdentifier)
        XCTAssertTrue(effects.outputs.isEmpty)
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        XCTAssertEqual(FakeLog.shared.huds.last?.phase, .postProcessing)
        effects.release()
        let final = await task.value
        XCTAssertEqual(final.result?.text, "raw provider")
        XCTAssertEqual(final.processedText, "Final cleanup")
        XCTAssertEqual(effects.requests.count, 1)
        XCTAssertEqual(effects.oneShotCount, 0)
        effects.emit("non-cooperative late partial")
        let count = FakeLog.shared.displayedTranscripts.count
        await host.publishCleanupPreview(
            "non-cooperative late partial", recordID: record.id, requestID: requestID, presentation: presentation
        )
        XCTAssertEqual(FakeLog.shared.displayedTranscripts.count, count)
        let stillSaved = try await host.store.record(id: record.id)
        XCTAssertNil(stillSaved.processedText, "Only the caller's final save may commit cleanup")
    }

    func testLegacyAndOwnedRecording_KeepAdmissionSnapshotAndOnlyCommitFinal() async throws {
        await host.close()
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopTranscription.provider(for: $0.id) != nil
        })
        let model = DesktopHostModels.all[index].id
        let worker = DictationFixtureWorker()
        let capability = DesktopHostOwnedDictationCapability(
            capability: .qualified, permission: .granted, makeWorker: { worker }
        )
        for owned in [false, true] {
            let path = directory.appendingPathComponent(owned ? "owned" : "legacy")
            let host = try DesktopHostController(
                directory: path, effects: effects, ownedDictationCapability: owned ? capability : nil
            )
            self.host = host
            await host.markReadyForSelfTest()
            let preferences = try DesktopConfiguration(values: [
                "postRecordingTailDuration": AnyCodable(.double(0))
            ])
            try await host.saveConfiguration(preferences.entries)
            for model in DesktopHostModels.all {
                if let provider = DesktopHostModels.provider(for: model.id) {
                    FakeLog.shared.setKey("synthetic transcription key", name: provider.apiKeyIdentifier)
                }
            }
            effects.key = "captured key"
            let profile = DesktopProfileSession.defaults(modelIdentifier: model, postProcessing: options())
            await host.toggleCaptured(
                target: "captured-field", modelIndex: index, deviceID: "synthetic",
                textOutput: FakeTextOutput(), profile: profile
            )
            let recordingID = await host.dictationSessionID
            let id = try XCTUnwrap(recordingID)
            effects.key = "later key"
            let entered = expectation(description: "cleanup after real \(owned ? "owned" : "legacy") stop")
            effects.entered = { entered.fulfill() }
            let stop = Task {
                await host.toggleCaptured(
                    target: "different-field", modelIndex: index, deviceID: "later",
                    textOutput: FakeTextOutput(label: "later"), profile: profile
                )
            }
            await fulfillment(of: [entered], timeout: 2)
            let raw = try await host.store.record(id: id)
            XCTAssertEqual(raw.result?.text, "Synthetic transcript")
            XCTAssertNil(raw.processedText)
            XCTAssertEqual(effects.requests.last?.key, "captured key")
            XCTAssertEqual(effects.requests.last?.options.customPrompt, "Captured prompt")
            let outputCount = effects.outputs.count
            effects.emit("incomplete")
            for _ in 0..<200 {
                if FakeLog.shared.huds.last?.liveText == "incomplete" { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "incomplete")
            XCTAssertEqual(effects.outputs.count, outputCount)
            let partial = try await host.store.record(id: id)
            XCTAssertNil(partial.processedText)
            effects.release()
            await stop.value
            let final = try await host.store.record(id: id)
            XCTAssertEqual(final.result?.text, "Synthetic transcript")
            XCTAssertEqual(final.processedText, "Final cleanup")
            let captures = await host.capturedCleanup
            XCTAssertTrue(captures.isEmpty)
            await host.close()
        }
    }

    func testCancelAndClose_RejectNonCooperativeChunksAndFinal() async throws {
        for close in [false, true] {
            if close { await host.cleanupTestResetCancellation() }
            let record = try await record()
            let entered = expectation(description: "entered held stream \(close)")
            effects.entered = { entered.fulfill() }
            let host = host!
            let options = options()
            let task = Task { await host.postProcess(record, options: options) }
            await fulfillment(of: [entered], timeout: 2)
            if close { _ = await host.close() } else { await host.cancelTranscription() }
            effects.emit("late forbidden preview")
            effects.release()
            let result = await task.value
            XCTAssertNil(result.processedText)
            XCTAssertNotNil(result.postProcessingFailure)
            XCTAssertFalse(FakeLog.shared.displayedTranscripts.contains("late forbidden preview"))
            XCTAssertTrue(effects.outputs.isEmpty)
            XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        }
    }

    func testReplacement_RejectsOldRequestWithoutClearingNewOwner() async throws {
        let first = try await record()
        let entered = expectation(description: "first entered")
        effects.entered = { entered.fulfill() }
        let host = host!
        let options = options()
        let task = Task { await host.postProcess(first, options: options) }
        await fulfillment(of: [entered], timeout: 2)
        let replacement = UUID()
        await host.cleanupTestReplaceRequest(replacement)
        effects.emit("old preview")
        effects.release()
        let result = await task.value
        XCTAssertNil(result.processedText)
        XCTAssertNotNil(result.postProcessingFailure)
        let owner = await host.postProcessingID
        XCTAssertEqual(owner, replacement)
        XCTAssertFalse(FakeLog.shared.displayedTranscripts.contains("old preview"))
    }

    func testAwayBackSelectionAndPresentation_NeverReviveOldPreviewToken() async throws {
        let record = try await record()
        let requestID = UUID()
        let presentation = await host.cleanupTestPreviewToken(requestID)
        await host.publishCleanupPreview("allowed", recordID: record.id, requestID: requestID, presentation: presentation)
        XCTAssertEqual(FakeLog.shared.displayedTranscripts.last, "allowed")
        await host.cleanupTestSelectionAwayBack(record.id)
        await host.publishCleanupPreview("selection stale", recordID: record.id,
                                        requestID: requestID, presentation: presentation)
        let second = await host.cleanupTestPreviewToken(requestID)
        await host.cleanupTestPresentationAwayBack()
        await host.publishCleanupPreview("presentation stale", recordID: record.id,
                                        requestID: requestID, presentation: second)
        XCTAssertFalse(FakeLog.shared.displayedTranscripts.contains("selection stale"))
        XCTAssertFalse(FakeLog.shared.displayedTranscripts.contains("presentation stale"))
    }

    func testPreviewBoundAndHUDPreference_DoNotChangeHistoryOrGlobalTranscript() async throws {
        let record = try await record()
        let request = UUID()
        let presentation = await host.cleanupTestPreviewToken(request)
        let text = String(repeating: "z", count: 1_000)
        await host.publishCleanupPreview(text, recordID: record.id, requestID: request, presentation: presentation)
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText?.count, DesktopHUDState.liveTextLimit)
        let transcript = await host.transcript
        XCTAssertEqual(transcript, "raw provider", "Copy/output authority must not become a partial")
        await host.publishCleanupPreview(String(repeating: "z", count: 65_537), recordID: record.id,
                                        requestID: request, presentation: presentation)
        XCTAssertEqual(FakeLog.shared.displayedTranscripts.last, text)
        let saved = try await host.store.record(id: record.id)
        XCTAssertNil(saved.processedText)
    }

    func testCapturedCredentialOptionsAndFailure_AreImmutableAcrossLaterSettings() async throws {
        let record = try await record()
        let original = options()
        let captured = await host.captureCleanup(original)
        XCTAssertNotNil(captured)
        effects.key = "later key"
        await host.cleanupTestCapture(captured, id: record.id)
        var later = original
        later.customPrompt = "Later prompt"
        later.temperature = 0.9
        let entered = expectation(description: "snapshot used")
        effects.entered = { entered.fulfill() }
        let host = host!
        let task = Task { await host.postProcess(record, options: later) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(effects.requests.first?.key, "captured key")
        XCTAssertEqual(effects.requests.first?.options.customPrompt, "Captured prompt")
        XCTAssertEqual(effects.requests.first?.options.temperature, original.temperature)
        effects.release()
        _ = await task.value
        effects.key = ""
        let failed = await host.captureCleanup(original)
        XCTAssertNotNil(failed?.failure)
        effects.key = "newly available key"
        await host.cleanupTestCapture(failed, id: record.id)
        let rejected = await host.postProcess(record, options: original)
        XCTAssertNil(rejected.processedText)
        XCTAssertNotNil(rejected.postProcessingFailure)
        XCTAssertEqual(effects.requests.count, 1, "A missing captured key must not be re-read or resent")
    }

    func testEmptyDisabledAndLegacyOneShot_DoNotEnterStreamingEffect() async throws {
        var empty = try await record()
        empty.result = .init(text: "", segments: [], confidence: nil, duration: 0,
                             modelIdentifier: empty.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil)
        let emptyResult = await host.postProcess(empty, options: options())
        XCTAssertEqual(emptyResult.processedText, "")
        let record = try await record()
        effects.key = ""
        let noInput = await host.postProcess(record, options: options(), inputText: "")
        XCTAssertEqual(noInput.processedText, "")
        XCTAssertNil(noInput.postProcessingFailure)
        let disabled = await host.postProcess(record, options: .init())
        XCTAssertNil(disabled.processedText)
        var legacy = options()
        legacy.streamingEnabled = false
        _ = await host.postProcess(record, options: legacy)
        XCTAssertEqual(effects.requests.count, 0)
        XCTAssertEqual(effects.oneShotCount, 1)
    }

    func testPreferenceApplyRestartImportExport_DoesNotGrantOtherConsent() async throws {
        let key = ApplicationPreferenceKey.postProcessingStreamingEnabled.rawValue
        var entries = try await host.configuration().entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
        entries[index] = "1"
        try await host.saveConfiguration(entries)
        let enabled = await host.postProcessingOptions()
        XCTAssertTrue(enabled.streamingEnabled)
        await host.close()
        host = try DesktopHostController(directory: directory, effects: effects)
        await host.markReadyForSelfTest()
        let restored = await host.postProcessingOptions()
        XCTAssertTrue(restored.streamingEnabled)
        let file = directory.appendingPathComponent("transfer.json")
        try await host.exportConfiguration(path: file.path)
        let export = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: file))
        XCTAssertEqual(export.preferences.values[key], AnyCodable(.bool(true)))
        let imported = DesktopConfigurationDocument(preferences: try DesktopConfiguration(values: [
            key: AnyCodable(.bool(true)), "speedMode": AnyCodable(.string("livePolish")),
            "postProcessingEnabled": AnyCodable(.bool(true)),
            "postProcessingModel": AnyCodable(.string("local/post-processing/imported-test")),
            "futureCleanup": AnyCodable(.string("preserved"))
        ]))
        try JSONEncoder().encode(imported).write(to: file)
        try await host.importConfiguration(path: file.path)
        let settings = await host.settings
        XCTAssertNotEqual(settings.livePolishApproved, true)
        XCTAssertEqual(settings.postProcessing?.mode, .disabled)
        XCTAssertEqual(settings.postProcessing?.streamingEnabled, true)
        XCTAssertEqual(settings.configuration?.values["futureCleanup"], AnyCodable(.string("preserved")))
        XCTAssertTrue(effects.requests.isEmpty)
    }

    func testPreferenceWriteFailure_RetainsPreviousRuntimeAndDisk() async throws {
        let key = DesktopPostProcessingConfiguration.streamingKey
        var entries = try await host.configuration().entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
        entries[index] = "0"
        try await host.saveConfiguration(entries)
        let file = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: file)
        effects.failWrites = true
        entries[index] = "1"
        do { try await host.saveConfiguration(entries); XCTFail("Write failure accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Synthetic settings write failure"))
        }
        let current = await host.postProcessingOptions()
        XCTAssertFalse(current.streamingEnabled)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(effects.requests.isEmpty)
    }

    func testLegacyCanonicalPreference_MigratesOnceWithoutOverridingExplicitOptions() throws {
        let key = DesktopPostProcessingConfiguration.streamingKey
        let legacy = #"{"model":"MODEL","configuration":{"KEY":true,"futureCleanup":"kept"}}"#
            .replacingOccurrences(of: "MODEL", with: ModelCatalog.defaultBatchTranscriptionModel)
            .replacingOccurrences(of: "KEY", with: key)
        let document = try JSONDecoder().decode(
            DesktopHostController<FakePlatform>.Settings.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(document.postProcessing?.streamingEnabled, true)
        XCTAssertEqual(document.postProcessing?.mode, .disabled)
        XCTAssertNil(document.configuration?.values[key])
        XCTAssertEqual(document.configuration?.values["futureCleanup"], AnyCodable(.string("kept")))
        let persisted = try JSONEncoder().encode(document)
        let restarted = try JSONDecoder().decode(DesktopHostController<FakePlatform>.Settings.self, from: persisted)
        XCTAssertEqual(restarted.postProcessing, document.postProcessing)
        var explicit = document
        explicit.postProcessing?.streamingEnabled = false
        explicit.configuration = try DesktopConfiguration(values: [key: AnyCodable(.bool(true))])
        let resolved = try JSONDecoder().decode(
            DesktopHostController<FakePlatform>.Settings.self, from: JSONEncoder().encode(explicit)
        )
        XCTAssertEqual(resolved.postProcessing?.streamingEnabled, false)
        XCTAssertNil(resolved.configuration?.values[key])
    }

    private func options() -> DesktopPostProcessing.Options {
        var options = DesktopPostProcessing.Options(mode: .remote, customPrompt: "Captured prompt")
        options.streamingEnabled = true
        return options
    }

    private func record() async throws -> DesktopRecordingStore.Record {
        let id = UUID()
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: id.uuidString + ".wav", modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.result = .init(text: "raw provider", segments: [], confidence: nil, duration: 1,
                              modelIdentifier: record.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil)
        try await host.saveRecord(record)
        await host.cleanupTestSelect(record.id)
        await host.beginHUD(record.id, .postProcessing)
        return record
    }

    private func waitForPreview(_ value: String) async throws {
        for _ in 0..<200 {
            if FakeLog.shared.displayedTranscripts.contains(value) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("No incremental Host preview before final completion")
    }
}

private final class CleanupHostEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    struct Request: Sendable { let key: String; let options: DesktopPostProcessing.Options }
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private let outcome: DesktopPostProcessing.Outcome
    private var calls: [Request] = []
    private var ordinary = 0
    private var credential = "captured key"
    private var callback: (@Sendable (String) -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    private var entry: (@Sendable () -> Void)?
    private var writingFails = false
    var failWrites: Bool {
        get { lock.withLock { writingFails } }
        set { lock.withLock { writingFails = newValue } }
    }
    var entered: (@Sendable () -> Void)? {
        get { lock.withLock { entry } }
        set { lock.withLock { entry = newValue } }
    }
    var key: String {
        get { lock.withLock { credential } }
        set { lock.withLock { credential = newValue } }
    }
    var requests: [Request] { lock.withLock { calls } }
    var oneShotCount: Int { lock.withLock { ordinary } }
    var outputs: [(FakeJob, String)] { base.outputs }
    init(outcome: DesktopPostProcessing.Outcome) { self.outcome = outcome }
    func emit(_ text: String) { lock.withLock { callback }?(text) }
    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiter = nil }; return waiter
        }
        pending?.resume()
    }
    func apiKey(name: String) throws -> String { key }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(model: String, key: String, language: String?, azureEndpoint: String)
        -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(_ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>)
        async throws -> TranscriptionResult { try await base.transcribe(request, with: controller) }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws {
        if failWrites { throw DesktopHostError(message: "Synthetic settings write failure") }
        try base.writeSettings(data, to: url)
    }
    func postProcess(text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String])
        async throws -> DesktopPostProcessing.Outcome {
        lock.withLock { ordinary += 1 }
        return outcome
    }
    func postProcessStreaming(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String],
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> DesktopPostProcessing.Outcome {
        await withCheckedContinuation { continuation in
            let notify = lock.withLock {
                calls.append(.init(key: key, options: options))
                callback = onUpdate
                waiter = continuation
                return entry
            }
            notify?()
        }
        // Deliberately ignores cancellation and retains its callback for stale-chunk tests.
        return outcome
    }
}

private extension DesktopHostController where Platform == FakePlatform {
    func cleanupTestSelect(_ id: UUID) {
        selectedHistoryID = id
        transcriptVariant = .processed
        transcript = "raw provider"
        busy = true
    }
    func cleanupTestCapture(_ input: DesktopHostCleanupInput?, id: UUID) { capturedCleanup[id] = input }
    func cleanupTestResetCancellation() { cancellationRequested = false }
    func cleanupTestReplaceRequest(_ id: UUID) { postProcessingID = id }
    func cleanupTestPreviewToken(_ id: UUID) -> UUID {
        postProcessingID = id
        return cleanupPresentationEpoch
    }
    func cleanupTestSelectionAwayBack(_ id: UUID) {
        selectedHistoryID = UUID()
        selectedHistoryID = id
    }
    func cleanupTestPresentationAwayBack() {
        comparisonVisible = true
        comparisonVisible = false
    }
}
