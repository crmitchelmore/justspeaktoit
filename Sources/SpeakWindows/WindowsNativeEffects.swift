import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

struct WindowsNativeEffects: WindowsControllerEffects {
    /// Deliberately not selected by Main. The caller must supply actual native
    /// qualification and permission evidence, not a saved setting.
    static func ownedDictationCapability(
        capability: DesktopPressCaptureCapability, permission: DesktopPressCapturePermission
    ) -> DesktopHostOwnedDictationCapability {
        DesktopHostOwnedDictationCapability(capability: capability, permission: permission) {
            DesktopOwnedCaptureWorker(factory: WindowsOwnedCaptureDriverFactory())
        }
    }

    func apiKey(name: String) throws -> String { try WindowsNative.apiKey(name: name) }

    func warmPostProcessingConnection() async throws {
        try await OpenRouterConnectionWarmer.warmUp()
    }

    func makeCapture(
        context: WindowsCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any WindowsRecordingCapture {
        try WindowsNativeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint, options: .init())
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        DesktopLiveTranscription.makeClient(
            model: model, apiKey: key, language: language, azureEndpoint: azureEndpoint, options: options,
            makeConnection: { WinHTTPStreamingConnection(request: $0) }
        )
    }

    func transcribe(
        _ request: WindowsTranscriptionRequest, with controller: WindowsAppController
    ) async throws -> TranscriptionResult {
        try await controller.transcribePreparedAudio(request)
    }

    func perform(_ job: WindowsOutputJob, text: String) -> DesktopTextOutputResult { job.performResult(text) }

    func captureInsertionTarget() async throws -> WindowsInsertionTarget? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try WindowsInsertionTarget.capture()
        }.value
    }

    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }

    func prepareCaptureWhileIdle(
        deviceID: String, lifetimeMilliseconds: UInt32
    ) -> (any DesktopCapturePreparation)? {
        WindowsCapturePreparation(deviceID: deviceID, lifetimeMilliseconds: lifetimeMilliseconds)
    }

    func voiceCommandClipboardText() async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var pointer: UnsafeMutablePointer<CChar>?
            var error = [CChar](repeating: 0, count: 256)
            let result = jsti_voice_command_clipboard_read(&pointer, &error, error.count)
            defer { jsti_voice_command_clipboard_free(pointer) }
            guard result >= 0 else { throw WindowsNativeError(message: String(cString: error)) }
            guard result == 0, let pointer else { return nil }
            return String(cString: pointer)
        }.value
    }
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
