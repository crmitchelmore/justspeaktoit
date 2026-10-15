import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class VoiceCommandEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let base = SyntheticEffects()
    let clipboardEntered = Gate(open: false)
    var clipboardGate: Gate?
    var clipboardError: Error?
    private let lock = NSLock()
    private var snapshot: String? = "Synthetic clipboard"
    private var count = 0
    private var polished: [String] = []
    var text = "please copy pasta"
    var clipboard: String? {
        get { lock.withLock { snapshot } }
        set { lock.withLock { snapshot = newValue } }
    }
    var reads: Int { lock.withLock { count } }
    var polishInputs: [String] { lock.withLock { polished } }

    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        lock.withLock { polished.append(text) }
        return try await DesktopPostProcessing.process(rawText: text + " polished", options: .init(), apiKey: "")
    }

    func voiceCommandClipboardText() async throws -> String? {
        lock.withLock { count += 1 }
        clipboardEntered.release()
        if let clipboardGate { await clipboardGate.pass() }
        try Task.checkCancellation()
        if let clipboardError { throw clipboardError }
        return clipboard
    }

    func apiKey(name: String) throws -> String { "synthetic-key" }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: request.duration, modelIdentifier: request.model,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws { try base.writeSettings(data, to: url) }
}
