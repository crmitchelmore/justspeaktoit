import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

/// One recording's audio source, created stopped. The controller serialises
/// start, stop and destroy; destroy runs exactly once, after which no callback
/// reaches the capture context.
protocol WindowsRecordingCapture: AnyObject {
    func start() throws
    func stop() throws
    func destroy()
}

/// Batch transcription input for one saved recording.
struct WindowsTranscriptionRequest: Sendable {
    let audio: URL
    let model: String
    let key: String
    let duration: TimeInterval
    let language: String?
}

/// Native, provider and file effects at the edge of the controller's recording,
/// settings and output workflow. The app uses the Windows adapters; the
/// executable self-test substitutes synthetic ones so that workflow runs
/// without a microphone, credentials, network, clipboard or other application.
protocol WindowsControllerEffects: Sendable {
    func apiKey(name: String) throws -> String
    func makeCapture(
        context: WindowsCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any WindowsRecordingCapture
    func makeLiveClient(model: String, key: String, language: String?) -> (any FinalizingStreamingTranscriptionClient)?
    func transcribe(
        _ request: WindowsTranscriptionRequest, with controller: WindowsAppController
    ) async throws -> TranscriptionResult
    /// Blocking automatic output, called off the UI thread and the controller.
    func perform(_ job: WindowsOutputJob, text: String) -> String
    /// Replaces the settings file atomically.
    func writeSettings(_ data: Data, to url: URL) throws
}

struct WindowsNativeEffects: WindowsControllerEffects {
    func apiKey(name: String) throws -> String { try WindowsNative.apiKey(name: name) }

    func makeCapture(
        context: WindowsCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any WindowsRecordingCapture {
        try WindowsNativeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }

    func makeLiveClient(
        model: String, key: String, language: String?
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        DesktopLiveTranscription.makeClient(
            model: model, apiKey: key, language: language, makeConnection: { WinHTTPStreamingConnection(request: $0) }
        )
    }

    func transcribe(
        _ request: WindowsTranscriptionRequest, with controller: WindowsAppController
    ) async throws -> TranscriptionResult {
        try await controller.transcribePreparedAudio(
            request.audio, model: request.model, key: request.key, duration: request.duration,
            language: request.language
        )
    }

    func perform(_ job: WindowsOutputJob, text: String) -> String { job.perform(text) }

    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// WASAPI capture. Keeps the context its native callbacks borrow alive until
/// destroy has joined the capture worker.
final class WindowsNativeCapture: WindowsRecordingCapture {
    private let native: OpaquePointer
    private let context: WindowsCaptureContext

    init(context: WindowsCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int) throws {
        native = try WindowsNative.createCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
        self.context = context
    }

    func start() throws { try WindowsNative.checked { jsti_capture_start(native, $0, $1) } }

    func stop() throws { try WindowsNative.checked { jsti_capture_stop(native, $0, $1) } }

    func destroy() { withExtendedLifetime(context) { jsti_capture_destroy(native) } }
}
