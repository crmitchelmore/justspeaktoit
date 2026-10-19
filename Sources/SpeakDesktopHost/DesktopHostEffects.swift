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
    package let keywords: [String]
    /// An explicit override; nil lets the adapter fall back to the saved Azure
    /// Speech resource captured at the start of its own transcription attempt.
    package let azureEndpoint: String?
    package var historySaved = true

    package init(
        audio: URL, model: String, key: String, duration: TimeInterval, language: String?, keywords: [String] = [],
        azureEndpoint: String? = nil
    ) {
        self.audio = audio
        self.model = model
        self.key = key
        self.duration = duration
        self.language = language
        self.keywords = keywords
        self.azureEndpoint = azureEndpoint
    }
}

/// Native, provider and file effects at the edge of the controller's recording,
/// settings and output workflow. The app uses the platform adapters; the
/// executable self-test substitutes synthetic ones so that workflow runs
/// without a microphone, credentials, network, clipboard or other application.
package protocol DesktopHostEffects<Platform>: Sendable {
    associatedtype Platform: DesktopHostPlatform
    func apiKey(name: String) throws -> String
    /// Explicit native opt-in: only the actual completed-request shared pool.
    func warmPostProcessingConnection() async throws
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture
    /// `azureEndpoint` is the saved Azure Speech resource; other routes ignore it.
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)?
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)?
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult
    func transcribeComparison(
        _ request: DesktopHostTranscriptionRequest, azureEndpoint: String,
        with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult
    /// Blocking automatic output, called off the UI thread and the controller.
    func perform(_ job: Platform.OutputJob, text: String) -> DesktopTextOutputResult
    /// Captures the automatic utterance's destination away from PCM and the UI thread.
    func captureInsertionTarget() async throws -> Platform.InsertionTarget?
    /// Read-only snapshot for a matched voice command; never called for other text.
    func voiceCommandClipboardText() async throws -> String?
    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome
    func postProcessStreaming(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String],
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> DesktopPostProcessing.Outcome
    func polishLive(
        text: String, model: String, key: String, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> String
    /// Replaces the settings file atomically.
    func writeSettings(_ data: Data, to url: URL) throws
}

package extension DesktopHostEffects {
    func warmPostProcessingConnection() async throws {
        throw DesktopHostError(message: "This host has no shared-session cleanup connection preparation.")
    }

    func postProcessStreaming(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String],
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> DesktopPostProcessing.Outcome {
        try await DesktopPostProcessing.process(
            rawText: text, options: options, apiKey: key,
            lexiconDirectives: directives, lexiconContextTags: tags, localLLM: nil, onUpdate: onUpdate
        )
    }

    func polishLive(
        text: String, model: String, key: String, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> String {
        try await DesktopPostProcessing.polishLive(text: text, model: model, apiKey: key, localLLM: localLLM)
    }

    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        try await DesktopPostProcessing.process(
            rawText: text, options: options, apiKey: key,
            lexiconDirectives: directives, lexiconContextTags: tags
        )
    }

    func voiceCommandClipboardText() async throws -> String? {
        throw DesktopHostError(message: "This host cannot read clipboard voice commands.")
    }

    func captureInsertionTarget() async throws -> Platform.InsertionTarget? {
        throw DesktopHostError(message: "This host cannot capture a hands-free insertion destination.")
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }
    func transcribeComparison(
        _ request: DesktopHostTranscriptionRequest, azureEndpoint: String,
        with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult {
        try await controller.transcribeComparison(request, endpoint: azureEndpoint)
    }
}

/// Owned until native capture stop has joined its worker, so no callback sees
/// freed state.
package final class DesktopCaptureContext: @unchecked Sendable {
    package let file: PCMRecordingFile?
    package let live: DesktopLiveSession?
    package let comparison: DesktopComparisonLive?
    package let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var failed = false
    private var silence: DictationSilenceMonitor?
    private var receivedSeconds = 0.0
    private let sampleRate: Int
    private let onSilence: (@Sendable () -> Void)?
    private let onPCM: (@Sendable (UnsafePointer<Int16>, Int) -> Void)?

    package init(
        file: PCMRecordingFile, live: DesktopLiveSession? = nil, comparison: DesktopComparisonLive? = nil,
        sampleRate: Int = PCMRecordingFile.sampleRate,
        silence: DictationSilenceMonitor? = nil, onSilence: (@Sendable () -> Void)? = nil,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.file = file
        self.live = live
        self.comparison = comparison
        self.onFailure = onFailure
        self.sampleRate = sampleRate
        self.silence = silence
        self.onSilence = onSilence
        self.onPCM = nil
    }

    package init(
        onPCM: @escaping @Sendable (UnsafePointer<Int16>, Int) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        file = nil
        live = nil
        comparison = nil
        sampleRate = PCMRecordingFile.sampleRate
        onSilence = nil
        self.onPCM = onPCM
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
        guard count > 0 else { fail("The microphone supplied an invalid PCM frame."); return }
        if let onPCM { onPCM(samples, count); return }
        do {
            let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
            try file?.append(data)
            live?.sendAudio(data)
            comparison?.sendAudio(data)
            let shouldStop = lock.withLock { () -> Bool in
                guard silence != nil, !failed else { return false }
                receivedSeconds += Double(count) / Double(sampleRate)
                let level = DictationSilencePolicy.normalizedLevel(UnsafeBufferPointer(start: samples, count: count))
                return silence?.observe(level: level, atSeconds: receivedSeconds) == true
            }
            if shouldStop { onSilence?() }
        } catch {
            fail(error.localizedDescription)
        }
    }

    package func receiveBuffered(_ data: Data) {
        do {
            try file?.append(data)
            guard let live else { return }
            let frameBytes = sampleRate * MemoryLayout<Int16>.size / 10
            for offset in stride(from: 0, to: data.count, by: frameBytes) {
                live.sendAudio(data.subdata(in: offset..<min(offset + frameBytes, data.count)))
            }
        } catch { fail(error.localizedDescription) }
    }

    /// Failed/cancelled startup owns audio, but never a provider-ready session.
    package func receiveRecovery(_ data: Data) {
        do { try file?.append(data) } catch { fail(error.localizedDescription) }
    }
}
