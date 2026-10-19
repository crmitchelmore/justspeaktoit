import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopComparisonHostTests: XCTestCase {
    func testBatchSnapshotsAllSamplesBeforeRequestsAndNeverMutatesHistoryOrSettings() async throws {
        DesktopHostModels.configure(streamingQualified: false)
        defer { DesktopHostModels.configure(streamingQualified: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.wav")
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 4, count: 3200), sampleRate: 16000))
        try bytes.write(to: source)
        let second = root.appendingPathComponent("second.wav")
        try bytes.write(to: second)
        let effects = ComparisonHostEffects(sourceToMutate: second)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let existing = try await seedComparisonHistory(controller)
        let historyDirectory = await controller.store.directory
        let historyMetadata = historyDirectory.appendingPathComponent(existing.id.uuidString + ".json")
        let historyBeforeComparison = try Data(contentsOf: historyMetadata)
        let selected = Array(DesktopHostModels.visible.prefix(2)).map(\.id)
        XCTAssertEqual(selected.count, 2)
        let originalSettings = await controller.settings.model
        await controller.comparisonEvent(
            102, text: "en_GB\n" + selected.joined(separator: "\t") + "\n" + source.path + "\n" + second.path,
            index: 0
        )
        await controller.comparisonTask?.value
        let persisted = await controller.comparisons
        let store = try XCTUnwrap(persisted)
        let rounds = await store.rounds()
        XCTAssertEqual(rounds.count, 2)
        XCTAssertTrue(rounds.allSatisfy { $0.inputMode == .batch && $0.language == "en_GB" })
        XCTAssertTrue(
            rounds.allSatisfy { $0.entries.allSatisfy { $0.transcript == "Raw only" } },
            rounds.flatMap(\.entries).compactMap(\.errorDescription).joined(separator: "\n")
        )
        XCTAssertEqual(effects.bytes, [bytes, bytes, bytes, bytes])
        let settingsAfterRun = await controller.settings.model
        XCTAssertEqual(settingsAfterRun, originalSettings)
        let history = try await controller.store.recoverInterruptedRecordings()
        XCTAssertEqual(history.records.map(\.id), [existing.id])
        XCTAssertEqual(try Data(contentsOf: historyMetadata), historyBeforeComparison)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
        let exported = root.appendingPathComponent("export.json")
        await controller.comparisonEvent(107, text: exported.path, index: 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ModelComparisonExport.Document.self, from: Data(contentsOf: exported))
        XCTAssertEqual(document.rounds.count, 2)
        XCTAssertEqual(document.schemaVersion, 1)
        await controller.close()
    }

    func testConfiguredModulateFlags_ReachRawBatchLanesWithoutNormalKeywords() async throws {
        DesktopHostModels.configure(streamingQualified: false)
        defer { DesktopHostModels.configure(streamingQualified: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try seedModulateComparisonSettings(root)
        let source = root.appendingPathComponent("input.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 4, count: 3200), sampleRate: 16_000))
            .write(to: source)
        let effects = ComparisonHostEffects(sourceToMutate: root.appendingPathComponent("mutable-fixture"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let models = ["modulate/velma-2-stt", "openai/whisper-1"]
        await controller.comparisonEvent(
            102, text: "\n" + models.joined(separator: "\t") + "\n" + source.path, index: 0
        )
        await controller.comparisonTask?.value
        XCTAssertEqual(effects.requests.count, 2)
        for request in effects.requests {
            XCTAssertEqual(request.modulateFeatures, .init(
                speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
            ))
            XCTAssertEqual(request.keywords, [])
        }
        let history = try await controller.store.records()
        XCTAssertTrue(history.isEmpty)
        await controller.close()
    }

    func testCancellationAndCloseKeepPendingAudioWithoutNormalHistory() async throws {
        DesktopHostModels.configure(streamingQualified: false)
        defer { DesktopHostModels.configure(streamingQualified: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.wav")
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 4, count: 3200), sampleRate: 16000))
        try bytes.write(to: source)
        let gate = Gate(open: false)
        let effects = ComparisonHostEffects(sourceToMutate: source, gate: gate)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let selected = Array(DesktopHostModels.visible.prefix(2)).map(\.id)
        let payload = "\n" + selected.joined(separator: "\t") + "\n" + source.path
        await controller.comparisonEvent(102, text: payload, index: 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while effects.bytes.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(effects.bytes.count, 2)
        await controller.comparisonEvent(102, text: payload, index: 0)
        XCTAssertEqual(effects.bytes.count, 2, "A busy comparison must not admit a second run")
        let task = await controller.comparisonTask
        let report = await controller.close()
        await task?.value
        gate.release()
        XCTAssertTrue(report.isComplete)
        let store = try DesktopComparisonStore(directory: root.appendingPathComponent("Comparisons"))
        let rounds = await store.rounds()
        XCTAssertEqual(rounds.count, 1)
        XCTAssertTrue(rounds[0].entries.allSatisfy(\.didFail))
        let retained = root.appendingPathComponent("Comparisons/Samples/\(rounds[0].id.uuidString).wav")
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
        let history = try await controller.store.recoverInterruptedRecordings()
        XCTAssertTrue(history.records.isEmpty)
    }

    func testLiveUsesOneCaptureAndPreservesPendingBlindIdentityThroughStop() async throws {
        DesktopHostModels.configure(streamingQualified: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = ComparisonHostEffects(sourceToMutate: root, liveEnabled: true)
        try seedModulateComparisonSettings(root)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let selected = Array(DesktopHostModels.visible.filter {
            DesktopHostModels.isLive($0.id) && LiveTranscriptionRouting.route(for: $0.id)?.sampleRate == 24_000
        }.prefix(2)).map(\.id)
        XCTAssertEqual(selected.count, 2)
        await controller.comparisonEvent(103, text: "\n" + selected.joined(separator: "\t"), index: 0)
        let preparation = await controller.comparisonTask
        await preparation?.value
        XCTAssertEqual(effects.captureCount, 1)
        let persistence = await controller.comparisons
        let store = try XCTUnwrap(persistence)
        let pending = await store.rounds()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(effects.liveClients.count, 2)
        XCTAssertEqual(effects.options.count, 2)
        for options in effects.options {
            XCTAssertEqual(options.modulate, .init(
                speakerDiarization: true, emotionSignal: true, accentSignal: true, piiPhiTagging: true
            ))
            XCTAssertEqual(options.keywords, [])
            XCTAssertEqual(options.assemblyAIKeyterms, [])
        }
        XCTAssertEqual(effects.liveClients[0].audio, effects.liveClients[1].audio)
        XCTAssertEqual(effects.liveClients[0].audio.count, 1)
        let generation = await controller.comparisonGeneration
        await controller.startComparisonUpdates(generation: generation, deadline: .now)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await controller.comparisonCapture != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalization = await controller.comparisonFinalization
        await finalization?.value
        let capture = await controller.comparisonCapture
        XCTAssertNil(capture, "The comparison safety deadline must stop the one native capture.")
        let rounds = await store.rounds()
        XCTAssertEqual(rounds[0].blindOrder, pending[0].blindOrder)
        XCTAssertEqual(rounds[0].entries.map(\.id), pending[0].entries.map(\.id))
        XCTAssertTrue(rounds[0].entries.allSatisfy { $0.transcript == "Raw live" && !$0.didFail })
        XCTAssertGreaterThan(rounds[0].sample.durationSeconds, 0)
        let history = try await controller.store.recoverInterruptedRecordings()
        XCTAssertTrue(history.records.isEmpty)
        await controller.close()
    }
}

private func seedModulateComparisonSettings(_ root: URL) throws {
    var values = Dictionary(uniqueKeysWithValues: DesktopConfiguration.modulatePreferenceKeys.map {
        ($0, AnyCodable.JSONValue.bool(true))
    })
    values["transcriptionKeywords"] = .string("Not part of raw comparisons")
    let settings: [String: AnyCodable] = [
        "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
        "configuration": AnyCodable(.object(values))
    ]
    try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"))
}

private func seedComparisonHistory(
    _ controller: DesktopHostController<FakePlatform>
) async throws -> DesktopRecordingStore.Record {
    var record = DesktopRecordingStore.Record(
        syncedID: UUID(), createdAt: Date(), modelIdentifier: "existing/model", originPlatform: "macos"
    )
    record.result = TranscriptionResult(
        text: "Existing raw", segments: [], confidence: nil, duration: 1, modelIdentifier: "existing/model",
        cost: nil, rawPayload: nil, debugInfo: nil
    )
    record.processedText = "Existing processed"
    try await controller.store.save(record)
    return record
}

extension FakePlatform {
    static var comparisonDigest: LocalModelDigestProvider? {
        LocalModelDigestProvider(name: "Synthetic test identity") { ComparisonTestHasher() }
    }
}

private final class ComparisonTestHasher: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws {}
    func finish() throws -> String { String(repeating: "a", count: 64) }
}

private final class ComparisonHostEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let lock = NSLock()
    private var observed: [Data] = []
    private var captures = 0
    private var clients: [HostComparisonClient] = []
    private var capturedRequests: [DesktopHostTranscriptionRequest] = []
    private var capturedOptions: [LiveClientOptions] = []
    let sourceToMutate: URL
    let gate: Gate?
    let liveEnabled: Bool
    var bytes: [Data] { lock.withLock { observed } }
    var captureCount: Int { lock.withLock { captures } }
    var liveClients: [HostComparisonClient] { lock.withLock { clients } }
    var requests: [DesktopHostTranscriptionRequest] { lock.withLock { capturedRequests } }
    var options: [LiveClientOptions] { lock.withLock { capturedOptions } }
    init(sourceToMutate: URL, gate: Gate? = nil, liveEnabled: Bool = false) {
        self.sourceToMutate = sourceToMutate; self.gate = gate; self.liveEnabled = liveEnabled
    }
    func apiKey(name: String) throws -> String { "synthetic-key" }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        lock.withLock { captures += 1 }
        XCTAssertEqual(frameMilliseconds, 100)
        return SyntheticCapture(context: context)
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        guard liveEnabled else { return nil }
        let client = HostComparisonClient(gate: gate)
        lock.withLock { clients.append(client) }
        return client
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { throw DesktopHostError(message: "Normal pipeline must not run.") }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        lock.withLock { capturedOptions.append(options) }
        return makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }
    func transcribeComparison(
        _ request: DesktopHostTranscriptionRequest, azureEndpoint: String,
        with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        let data = try Data(contentsOf: request.audio)
        let mutateOriginal = lock.withLock {
            observed.append(data)
            capturedRequests.append(request)
            return observed.count == 1
        }
        await gate?.pass()
        try Task.checkCancellation()
        if mutateOriginal {
            try Data("Changed original during the first sample request".utf8).write(to: sourceToMutate)
        }
        return TranscriptionResult(
            text: "Raw only", segments: [], confidence: nil, duration: request.duration, modelIdentifier: request.model,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        XCTFail("No automatic output.")
        return DesktopTextOutputResult(.confirmedInsertion, status: "")
    }
    func writeSettings(_ data: Data, to url: URL) throws { XCTFail("No settings mutation.") }
}

private final class HostComparisonClient: FinalizingStreamingTranscriptionClient,
    StreamingAudioReadyProviding, @unchecked Sendable {
    let isReadyForAudio = true
    let finalShape = TranscriptFinalShape.cumulativeTranscript
    private let lock = NSLock()
    private var frames: [Data] = []
    private var finishing = false
    let gate: Gate?
    init(gate: Gate? = nil) { self.gate = gate }
    var audio: [Data] { lock.withLock { frames } }
    var hasBegunFinish: Bool { lock.withLock { finishing } }
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {}
    func sendAudio(_ audioData: Data) { lock.withLock { frames.append(audioData) } }
    func stop() {}
    func finishAndWait() async -> String? {
        lock.withLock { finishing = true }
        await gate?.pass()
        return "Raw live"
    }
}

extension DesktopComparisonHostTests {
    func testPersistedRoundDeletionUsesOwnedAdmissionAndKeepsOriginalImportAndHistory() async throws {
        DesktopHostModels.configure(streamingQualified: false)
        defer { DesktopHostModels.configure(streamingQualified: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        let bytes = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 4, count: 3200), sampleRate: 16000))
        try bytes.write(to: source)
        let effects = ComparisonHostEffects(sourceToMutate: root.appendingPathComponent("mutable-fixture"))
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let existing = try await seedComparisonHistory(controller)
        let selected = Array(DesktopHostModels.visible.prefix(2)).map(\.id)
        let payload = "\n" + selected.joined(separator: "\t") + "\n" + source.path
        await controller.comparisonEvent(102, text: payload, index: 0)
        let running = await controller.comparisonTask
        await running?.value
        let persistence = await controller.comparisons
        let store = try XCTUnwrap(persistence)
        let rounds = await store.rounds()
        let round = try XCTUnwrap(rounds.first)
        await controller.comparisonEvent(120, text: round.id.uuidString, index: 0)
        let deletion = await controller.comparisonTask
        await deletion?.value
        let remaining = await store.rounds()
        let pending = await store.pendingRevisions()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.round)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let history = try await controller.store.recoverInterruptedRecordings()
        XCTAssertEqual(history.records.map(\.id), [existing.id])
        let busy = await controller.busy
        XCTAssertFalse(busy)
        await controller.close()
    }

    func testSerializedStopEventReturnsBeforeFinalizationSoCancelCanRun() async throws {
        DesktopHostModels.configure(streamingQualified: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(open: false)
        defer { gate.release() }
        let effects = ComparisonHostEffects(sourceToMutate: root, gate: gate, liveEnabled: true)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let selected = Array(DesktopHostModels.visible.filter {
            DesktopHostModels.isLive($0.id) && LiveTranscriptionRouting.route(for: $0.id)?.sampleRate == 24_000
        }.prefix(2)).map(\.id)
        await controller.comparisonEvent(103, text: "\n" + selected.joined(separator: "\t"), index: 0)
        let preparation = await controller.comparisonTask
        await preparation?.value
        let started = ContinuousClock.now
        await controller.comparisonEvent(104, text: "", index: 0)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !effects.liveClients.allSatisfy(\.hasBegunFinish), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(effects.liveClients.count, 2)
        XCTAssertTrue(effects.liveClients.allSatisfy(\.hasBegunFinish))
        let finalization = await controller.comparisonFinalization
        XCTAssertNotNil(finalization)
        await controller.comparisonEvent(105, text: "", index: 0)
        await finalization?.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        let persistence = await controller.comparisons
        let rounds = await persistence?.rounds()
        XCTAssertEqual(rounds?.count, 1)
        XCTAssertTrue(try XCTUnwrap(rounds).flatMap(\.entries).allSatisfy(\.didFail))
        let stillBusy = await controller.busy
        XCTAssertFalse(stillBusy)
        await controller.close()
    }
}
