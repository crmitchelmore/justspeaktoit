import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class AutoCleanEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    struct Call: Equatable {
        let text: String
        let model: String
        let key: String
    }
    struct LiveClientCall: Equatable {
        let model: String
        let key: String
    }
    let client = AutoCleanStreamingClient()
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var key = "cleanup-key-at-start"
    private var reads: [String] = []
    private var liveClients: [LiveClientCall] = []
    private var cleaned: [Call] = []
    private var ordinary: [String] = []
    private var failure = false
    private var started: (@Sendable () -> Void)?
    private var held: CheckedContinuation<String, Error>?
    private var hold = false
    var keyReads: [String] { lock.withLock { reads } }
    var primaryKeyReads: [String] { lock.withLock { reads.filter { $0 == "assemblyai.apiKey" } } }
    var cleanupKeyReads: [String] { lock.withLock { reads.filter { $0 == "openrouter.apiKey" } } }
    var liveClientCalls: [LiveClientCall] { lock.withLock { liveClients } }
    var cleanups: [Call] { lock.withLock { cleaned } }
    var postProcesses: [String] { lock.withLock { ordinary } }
    var outputs: [(FakeJob, String)] { base.outputs }

    func setKey(_ value: String) { lock.withLock { key = value } }
    func failPolish() { lock.withLock { failure = true } }
    func holdPolish(onStart: @escaping @Sendable () -> Void) {
        lock.withLock { hold = true; started = onStart }
    }
    func releasePolish() {
        let waiter = lock.withLock { () -> CheckedContinuation<String, Error>? in
            defer { held = nil }
            return held
        }
        waiter?.resume(returning: "Too late.")
    }
    func apiKey(name: String) throws -> String {
        let cleanupKey = lock.withLock { reads.append(name); return key }
        if name == "openrouter.apiKey" { return cleanupKey }
        return try base.apiKey(name: name)
    }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try base.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        lock.withLock { liveClients.append(.init(model: model, key: key)) }
        return client
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        try await base.transcribe(request, with: controller)
    }
    func polishLive(
        text: String, model: String, key: String, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> String {
        let state = lock.withLock { () -> (Bool, Bool) in
            cleaned.append(.init(text: text, model: model, key: key))
            return (failure, hold)
        }
        if state.0 { throw DesktopHostError(message: "Injected Auto-Clean failure.") }
        if state.1 {
            return try await withCheckedThrowingContinuation { continuation in
                let notify = lock.withLock { held = continuation; return started }
                notify?()
            }
        }
        return "Clean: " + text
    }
    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        lock.withLock { ordinary.append(text) }
        return try await DesktopPostProcessing.process(
            rawText: text, options: .init(mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID),
            apiKey: ""
        )
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

final class AutoCleanStreamingClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    private let lock = NSLock()
    private var callback: ((String, Bool) -> Void)?
    private var failure: ((Error) -> Void)?
    private var text = ""
    var finalText = "authoritative raw"
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { callback = onTranscript; failure = onError }
    }
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? {
        lock.withLock { text = finalText; return finalText }
    }
    func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        lock.withLock { .init(displayText: text) }
    }
    func emit(_ value: String, final: Bool = false) {
        let receive = lock.withLock { text = value; return callback }
        receive?(value, final)
    }
    func fail() {
        let notify = lock.withLock { failure }
        notify?(DesktopHostError(message: "Injected live provider failure."))
    }
}

@MainActor
final class AutoCleanHostFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auto-clean-host-\(UUID())")
    let effects = AutoCleanEffects()
    var host: DesktopHostController<FakePlatform>!
    var modelIndex = 0
    let model = AssemblyAIModels.universal36ProStreamingID
    let worker = DictationFixtureWorker()

    func prepare(owned: Bool = false, skip: Bool = true, enabled: Bool = true) async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        for model in DesktopHostModels.all {
            if let provider = DesktopHostModels.provider(for: model.id) {
                FakeLog.shared.setKey("transcription-key", name: provider.apiKeyIdentifier)
            }
        }
        let worker = worker
        let capability = DesktopHostOwnedDictationCapability(
            capability: .qualified, permission: .granted, makeWorker: { worker }
        )
        host = try DesktopHostController(
            directory: directory, effects: effects, ownedDictationCapability: owned ? capability : nil
        )
        await host.markReadyForSelfTest()
        modelIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let configuration = try DesktopConfiguration(values: [
            "postRecordingTailDuration": AnyCodable(.int(0)),
            "speedMode": AnyCodable(.string(enabled ? "livePolish" : "instant")),
            "livePolishModel": AnyCodable(.string(ModelCatalog.defaultFastTextModel)),
            "skipPostProcessingWithLivePolish": AnyCodable(.bool(skip))
        ])
        try await host.saveConfiguration(configuration.entries)
    }

    func toggle() async {
        await host.toggle(
            target: "captured-field", modelIndex: modelIndex, deviceID: "synthetic",
            targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
    }

    func record() async throws -> DesktopRecordingStore.Record {
        let records = try await host.store.records()
        return try XCTUnwrap(records.first)
    }

    func cleanup() async throws {
        effects.releasePolish()
        await host.close()
        try FileManager.default.removeItem(at: directory)
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func autoCleanFixtureSettings(
        configuration: DesktopConfiguration? = nil, approved: Bool? = nil,
        options: DesktopPostProcessing.Options? = nil
    ) {
        if let configuration { settings.configuration = configuration }
        if let approved { settings.livePolishApproved = approved }
        if let options { settings.postProcessing = options }
    }
}
