import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class LocalRulesEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let base = SyntheticEffects()
    let entered = Gate(open: false)
    var gate: Gate?
    var refusesSettings = false
    private let lock = NSLock()
    struct Request {
        let text: String
        let key: String
        let directives: [String]
        let tags: [String]
        let options: DesktopPostProcessing.Options
    }
    private var inputs: [Request] = []
    var requests: [Request] { lock.withLock { inputs } }

    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        lock.withLock {
            inputs.append(Request(text: text, key: key, directives: directives, tags: tags, options: options))
        }
        // Remote requests are observed, never transmitted by this host double.
        let execution: DesktopPostProcessing.Options = options.mode == .remote ? .init() : options
        let outcome = try await DesktopPostProcessing.process(
            rawText: text, options: execution, apiKey: key, lexiconDirectives: directives, lexiconContextTags: tags
        )
        entered.release()
        // Return an already computed result even after cancellation, proving
        // that the controller checks cancellation at its ownership boundary.
        if let gate { await gate.pass() }
        return outcome
    }

    func voiceCommandClipboardText() async throws -> String? { "shared clipboard" }
    func apiKey(name: String) throws -> String { try base.apiKey(name: name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { try await base.transcribe(request, with: controller) }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult { base.perform(job, text: text) }
    func writeSettings(_ data: Data, to url: URL) throws {
        if refusesSettings { throw CocoaError(.fileWriteOutOfSpace) }
        try base.writeSettings(data, to: url)
    }
}

final class LocalRulesCredentialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var writeCount = 0
    var reads: Int { lock.withLock { readCount } }
    var writes: Int { lock.withLock { writeCount } }
    func read() { lock.withLock { readCount += 1 } }
    func write() { lock.withLock { writeCount += 1 } }
}
