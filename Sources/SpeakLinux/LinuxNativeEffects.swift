import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import SpeakLinuxWebSocket

/// The production effects: keyring credentials, libpulse capture, shared
/// provider clients and the native output job.
struct LinuxNativeEffects: DesktopHostEffects {
    typealias Platform = LinuxHostPlatform

    func apiKey(name: String) throws -> String { try LinuxCredentialStore.read(name: name) }

    func warmPostProcessingConnection() async throws {
        try await OpenRouterConnectionWarmer.warmUp()
    }

    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        try LinuxNativeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        LinuxLiveTransport.makeClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        LinuxLiveTransport.makeClient(
            model: model, key: key, language: language, azureEndpoint: azureEndpoint, options: options
        )
    }

    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: LinuxAppController
    ) async throws -> TranscriptionResult {
        try await controller.transcribePreparedAudio(request)
    }

    func perform(_ job: LinuxOutputJob, text: String) -> DesktopTextOutputResult { job.performResult(text) }

    func captureInsertionTarget() async throws -> LinuxInsertionTarget? {
        guard LinuxHostPlatform.session.canUseX11Injection else {
            throw DesktopHostError(
                message: "This desktop cannot freeze an external insertion destination. "
                    + "Use clipboard-only hands-free output or manual recording."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try LinuxX11.captureTargetChecked()
        }.value
    }

    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }

    /// X11 reads the active window's process for the canonical Linux matchers
    /// without probing its field; Wayland exposes no external app identity.
    func captureUtteranceContext(
        requiresInsertionTarget: Bool
    ) async throws -> DesktopHostUtteranceContext<LinuxInsertionTarget> {
        guard LinuxHostPlatform.session.canUseX11Injection else {
            if requiresInsertionTarget { _ = try await captureInsertionTarget() }
            return .init(
                target: nil, executablePath: nil,
                profileNotice: "Wayland does not expose the external app identity. Normal app settings apply."
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let target: LinuxInsertionTarget?
            if requiresInsertionTarget {
                target = try LinuxX11.captureTargetChecked()
            } else { target = try? LinuxX11.captureTargetChecked() }
            return DesktopHostUtteranceContext(
                target: requiresInsertionTarget ? target : nil, executablePath: target?.executablePath
            )
        }.value
    }

    func voiceCommandClipboardText() async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try LinuxClipboard.voiceCommandSnapshot()
        }.value
    }
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

/// Live transcription over SwiftNIO. The transport passes the same loopback
/// probe (echo, ping/pong, fragments, 2 MiB backpressure, cancellation,
/// oversize, Mistral scenarios) that qualified WinHTTP on Windows.
enum LinuxLiveTransport {
    static let qualified = true

    static func makeClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions = .init()
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        DesktopLiveTranscription.makeClient(
            model: model, apiKey: key, language: language, azureEndpoint: azureEndpoint, options: options,
            makeConnection: { NIOStreamingConnection(request: $0) }
        )
    }
}
