import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

actor ConnectionWarmProbe {
    private(set) var calls = 0
    private var held: [Int: CheckedContinuation<Void, Error>] = [:]
    private var onStart: (@Sendable () -> Void)?

    func notifyNextStart(_ callback: @escaping @Sendable () -> Void) { onStart = callback }

    /// Deliberately ignores cancellation to exercise retained ownership and ABA fences.
    func run() async throws {
        calls += 1
        let id = calls
        try await withCheckedThrowingContinuation { continuation in
            held[id] = continuation
            let callback = onStart
            onStart = nil
            callback?()
        }
    }

    func release(_ id: Int, success: Bool) {
        guard let continuation = held.removeValue(forKey: id) else { return }
        if success { continuation.resume() }
        else { continuation.resume(throwing: URLError(.notConnectedToInternet)) }
    }
}

final class ConnectionWarmEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let probe = ConnectionWarmProbe()
    private let base = SyntheticEffects()
    private let lock = NSLock()
    private var failCapture = false
    private var failSettings = false
    private var starts = 0
    var captureStarts: Int { lock.withLock { starts } }

    func refuseCapture() { lock.withLock { failCapture = true } }
    func refuseSettings() { lock.withLock { failSettings = true } }
    func apiKey(name: String) throws -> String { "synthetic-key-never-sent" }
    func warmPostProcessingConnection() async throws { try await probe.run() }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        WarmSyntheticCapture(context: context, fails: lock.withLock { failCapture }) { [self] in
            lock.withLock { starts += 1 }
        }
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { try await base.transcribe(request, with: controller) }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        try await DesktopPostProcessing.process(
            rawText: text,
            options: .init(mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID), apiKey: ""
        )
    }
    func writeSettings(_ data: Data, to url: URL) throws {
        if lock.withLock({ failSettings }) { throw CocoaError(.fileWriteOutOfSpace) }
        try base.writeSettings(data, to: url)
    }
}

private final class WarmSyntheticCapture: DesktopRecordingCapture {
    let base: SyntheticCapture
    let fails: Bool
    let onStart: @Sendable () -> Void
    init(context: DesktopCaptureContext, fails: Bool, onStart: @escaping @Sendable () -> Void) {
        base = SyntheticCapture(context: context)
        self.fails = fails
        self.onStart = onStart
    }
    func start() throws {
        onStart()
        if fails { throw DesktopHostError(message: "Synthetic capture start refused.") }
        try base.start()
    }
    func stop() throws { try base.stop() }
    func destroy() { base.destroy() }
}

extension DesktopHostController where Platform == FakePlatform {
    func installWarmContextForTest(
        options: DesktopPostProcessing.Options = .init(mode: .remote),
        model: String = ModelCatalog.defaultBatchTranscriptionModel,
        enabled: Bool = true, approved: Bool = true
    ) throws {
        var changed = settings
        changed.configuration = try DesktopConfiguration(values: [
            DesktopConnectionPreWarming.preferenceKey: AnyCodable(.bool(enabled))
        ])
        changed.postProcessing = options
        settings = changed
        connectionWarmApproved = approved
        acknowledgeConnectionWarmCapture(
            generation: connectionWarmGeneration, recordID: UUID(), model: model, options: options
        )
        connectionWarmCapture?.credentialsReady = true
    }

    func warmStateForTest() -> (approved: Bool, witness: Bool, eligible: Bool, warm: Bool, owned: Bool) {
        (
            connectionWarmApproved, connectionWarmCapture != nil, connectionWarmEligible,
            connectionWarmTracker.isWarm(host: OpenRouterConnectionWarmer.origin.host!, now: Date()),
            connectionWarmTask != nil
        )
    }

    func warmTaskForTest() -> Task<Void, Never>? { connectionWarmTask?.task }

    func renewWarmWitnessForTest() {
        let captured = connectionWarmCapture
        invalidateConnectionPreWarming(resetCapture: true)
        if let captured {
            acknowledgeConnectionWarmCapture(
                generation: connectionWarmGeneration, recordID: captured.recordID,
                model: captured.model, options: captured.options
            )
            connectionWarmCapture?.credentialsReady = captured.credentialsReady
        }
    }

    func warmOperationalBlockForTest(_ blocked: Bool) { busy = blocked }
    func warmReadinessForTest(_ ready: Bool) { isReady = ready }
    func warmOperationCycleForTest() { beginBusyOperation(); finishBusyOperation() }
    func warmBeginOperationForTest() { beginBusyOperation() }
    func warmStaleAcknowledgementForTest() {
        let old = connectionWarmGeneration
        invalidateConnectionPreWarming(resetCapture: true)
        acknowledgeConnectionWarmCapture(
            generation: old, recordID: UUID(), model: ModelCatalog.defaultBatchTranscriptionModel,
            options: .init(mode: .remote)
        )
    }
    func warmCredentialAcknowledgementForTest(matchesRecord: Bool, matchesModel: Bool, available: Bool) {
        guard let capture = connectionWarmCapture else { return }
        connectionWarmCapture?.credentialsReady = false
        acknowledgeConnectionWarmCleanupCredential(
            recordID: matchesRecord ? capture.recordID : UUID(),
            model: matchesModel ? capture.options.modelIdentifier : "unrelated/model", available: available
        )
    }
}
