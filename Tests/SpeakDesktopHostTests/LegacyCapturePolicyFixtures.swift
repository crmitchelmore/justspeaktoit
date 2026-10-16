import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class LegacyPolicyClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    let finishRelease = OwnedEventLatch()
    private let base: AutoCleanStreamingClient
    private let onFinish: @Sendable () -> Void

    init(base: AutoCleanStreamingClient, onFinish: @escaping @Sendable () -> Void) {
        self.base = base
        self.onFinish = onFinish
    }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        base.start(onTranscript: onTranscript, onError: onError)
    }
    func sendAudio(_ audioData: Data) { base.sendAudio(audioData) }
    func stop() { base.stop() }
    func finishAndWait() async -> String? {
        onFinish()
        await finishRelease.wait()
        return await base.finishAndWait()
    }
    func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        base.transcriptSnapshot(captureDuration: captureDuration)
    }
}

final class LegacyPolicyEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let base: AutoCleanEffects
    let client: LegacyPolicyClient

    init(onFinish: @escaping @Sendable () -> Void) {
        let base = AutoCleanEffects()
        self.base = base
        client = LegacyPolicyClient(base: base.client, onFinish: onFinish)
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
    ) -> (any FinalizingStreamingTranscriptionClient)? { client }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        try await base.transcribe(request, with: controller)
    }
    func polishLive(
        text: String, model: String, key: String, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> String {
        try await base.polishLive(text: text, model: model, key: key, localLLM: localLLM)
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}

extension DesktopHostController where Platform == FakePlatform {
    func legacyEventFixtureClearConfiguration() { settings.configuration = nil }

    func legacyEventFixtureAwaitOperations() async {
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }
}
