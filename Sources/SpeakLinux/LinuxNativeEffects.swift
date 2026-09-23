import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

/// The production effects: keyring credentials, libpulse capture, shared
/// provider clients and the native output job.
struct LinuxNativeEffects: DesktopHostEffects {
    typealias Platform = LinuxHostPlatform

    func apiKey(name: String) throws -> String { try LinuxCredentialStore.read(name: name) }

    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try LinuxNativeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }

    func makeLiveClient(
        model: String, key: String, language: String?
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        LinuxLiveTransport.makeClient(model: model, key: key, language: language)
    }

    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: LinuxAppController
    ) async throws -> TranscriptionResult {
        try await controller.transcribePreparedAudio(
            request.audio, model: request.model, key: request.key, duration: request.duration,
            language: request.language
        )
    }

    func perform(_ job: LinuxOutputJob, text: String) -> String { job.perform(text) }

    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// libpulse capture feeding the shared recording context. Keeps the context
/// its callbacks borrow alive until destroy has joined the audio thread.
final class LinuxNativeCapture: DesktopRecordingCapture {
    private let capture: LinuxAudioCapture
    private let context: DesktopCaptureContext

    init(context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int) throws {
        capture = try LinuxAudioCapture(
            device: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds,
            audio: { samples in
                guard let base = samples.baseAddress else { return }
                context.receive(base, count: samples.count)
            },
            failure: { context.fail($0) }
        )
        self.context = context
    }

    func start() throws { try capture.start() }
    func stop() throws { try capture.stop() }
    func destroy() { withExtendedLifetime(context) { capture.destroy() } }
}

/// Live transcription needs a WebSocket transport that passes the loopback
/// probe; until then Linux offers batch models only.
enum LinuxLiveTransport {
    static let qualified = false

    static func makeClient(
        model: String, key: String, language: String?
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
}
