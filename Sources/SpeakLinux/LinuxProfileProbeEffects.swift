import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

/// Explicit integration mode only. Native capture, X11 context, local
/// transcription and clipboard output are real; remote boundaries fail closed.
final class LinuxProfileProbeEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = LinuxHostPlatform

    struct Request: Codable, Equatable, Sendable {
        let model: String
        let language: String?
    }

    struct Evidence: Codable, Sendable {
        var credentialReads = 0
        var remoteLiveAttempts = 0
        var captureRates: [Int] = []
        var transcriptions: [Request] = []
        var contexts: [String] = []
        var copiedOutputs = 0
    }

    private let native = LinuxNativeEffects()
    private let lock = NSLock()
    private var evidence = Evidence()

    func snapshot() -> Evidence { lock.withLock { evidence } }

    func apiKey(name: String) throws -> String {
        lock.withLock { evidence.credentialReads += 1 }
        throw DesktopHostError(message: "The recorded profile fixture forbids credential reads.")
    }

    func warmPostProcessingConnection() async throws {
        throw DesktopHostError(message: "The recorded profile fixture forbids remote connection warming.")
    }

    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        lock.withLock { evidence.captureRates.append(sampleRate) }
        return try native.makeCapture(
            context: context, deviceID: deviceID, sampleRate: sampleRate, frameMilliseconds: frameMilliseconds
        )
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        lock.withLock { evidence.remoteLiveAttempts += 1 }
        return nil
    }

    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String, options: LiveClientOptions
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        makeLiveClient(model: model, key: key, language: language, azureEndpoint: azureEndpoint)
    }

    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: LinuxAppController
    ) async throws -> TranscriptionResult {
        guard DesktopHostModels.isLocal(request.model), request.key.isEmpty else {
            throw DesktopHostError(message: "The recorded profile fixture forbids remote transcription.")
        }
        lock.withLock { evidence.transcriptions.append(.init(model: request.model, language: request.language)) }
        return try await native.transcribe(request, with: controller)
    }

    func transcribeComparison(
        _ request: DesktopHostTranscriptionRequest, azureEndpoint: String, with controller: LinuxAppController
    ) async throws -> TranscriptionResult {
        throw DesktopHostError(message: "The recorded profile fixture forbids comparisons.")
    }

    func perform(_ job: LinuxOutputJob, text: String) -> DesktopTextOutputResult {
        let result = native.perform(job, text: text)
        if result.disposition == .copied { lock.withLock { evidence.copiedOutputs += 1 } }
        return result
    }

    func captureInsertionTarget() async throws -> LinuxInsertionTarget? {
        try await native.captureInsertionTarget()
    }

    func captureUtteranceContext(
        requiresInsertionTarget: Bool
    ) async throws -> DesktopHostUtteranceContext<LinuxInsertionTarget> {
        let context = try await native.captureUtteranceContext(requiresInsertionTarget: requiresInsertionTarget)
        lock.withLock { evidence.contexts.append(context.executablePath ?? "") }
        return context
    }

    func writeSettings(_ data: Data, to url: URL) throws { try native.writeSettings(data, to: url) }

    func postProcess(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String]
    ) async throws -> DesktopPostProcessing.Outcome {
        guard options.mode == .local, key.isEmpty else {
            throw DesktopHostError(message: "The recorded profile fixture forbids remote post-processing.")
        }
        return try await native.postProcess(text: text, options: options, key: key, directives: directives, tags: tags)
    }

    // swiftlint:disable:next function_parameter_count
    func postProcessStreaming(
        text: String, options: DesktopPostProcessing.Options, key: String, directives: [String], tags: [String],
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> DesktopPostProcessing.Outcome {
        throw DesktopHostError(message: "The recorded profile fixture forbids remote streaming cleanup.")
    }

    func polishLive(
        text: String, model: String, key: String, localLLM: (any DesktopLocalLLMEngine)?
    ) async throws -> String {
        throw DesktopHostError(message: "The recorded profile fixture forbids live polish.")
    }

    func rewriteSelection(_ request: DesktopVoiceEdit.Request, key: String) async throws -> String {
        throw DesktopHostError(message: "The recorded profile fixture forbids voice edit requests.")
    }
}
