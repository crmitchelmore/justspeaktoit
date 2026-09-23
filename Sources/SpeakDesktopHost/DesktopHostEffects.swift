import Foundation
import SpeakCore
import SpeakDesktop

/// One recording's audio source, created stopped. The controller serialises
/// start, stop and destroy; destroy runs exactly once, after which no callback
/// reaches the capture context.
package protocol DesktopRecordingCapture: AnyObject {
    func start() throws
    func stop() throws
    func destroy()
}

/// Batch transcription input for one saved recording.
package struct DesktopHostTranscriptionRequest: Sendable {
    package let audio: URL
    package let model: String
    package let key: String
    package let duration: TimeInterval
    package let language: String?
}

/// Native, provider and file effects at the edge of the controller's recording,
/// settings and output workflow. The app uses the platform adapters; the
/// executable self-test substitutes synthetic ones so that workflow runs
/// without a microphone, credentials, network, clipboard or other application.
package protocol DesktopHostEffects<Platform>: Sendable {
    associatedtype Platform: DesktopHostPlatform
    func apiKey(name: String) throws -> String
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture
    func makeLiveClient(model: String, key: String, language: String?) -> (any FinalizingStreamingTranscriptionClient)?
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult
    /// Blocking automatic output, called off the UI thread and the controller.
    func perform(_ job: Platform.OutputJob, text: String) -> String
    /// Replaces the settings file atomically.
    func writeSettings(_ data: Data, to url: URL) throws
}

/// Owned until native capture stop has joined its worker, so no callback sees
/// freed state.
package final class DesktopCaptureContext: @unchecked Sendable {
    package let file: PCMRecordingFile
    package let live: DesktopLiveSession?
    package let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var failed = false

    package init(
        file: PCMRecordingFile, live: DesktopLiveSession? = nil, onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.file = file
        self.live = live
        self.onFailure = onFailure
    }

    package func fail(_ message: String) {
        lock.lock()
        let firstFailure = !failed
        failed = true
        lock.unlock()
        if firstFailure { onFailure(message) }
    }

    /// One frame of mono PCM16 from the native capture thread: appended to the
    /// WAV first, then offered to any live session.
    package func receive(_ samples: UnsafePointer<Int16>, count: Int) {
        do {
            let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
            try file.append(data)
            live?.sendAudio(data)
        } catch {
            fail(error.localizedDescription)
        }
    }
}
