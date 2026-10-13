import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// Transcription blocks until cancelled or released.
final class GatedEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await gate.pass()
        try Task.checkCancellation()
        throw CancellationError()
    }
    func perform(_ job: FakeJob, text: String) -> String { "Delivered." }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}
