import AVFoundation
import Foundation
import SpeakCore

/// One model's session inside a live comparison: its client, transcript
/// accumulator and timing checkpoints.
@MainActor
final class ComparisonLiveLane {
    let candidate: ComparisonCandidate
    var entry: ModelComparisonEntry
    var captureStartedAt: Date?

    /// Cloud lanes: the shared client fed with PCM at `sampleRate`.
    private(set) var client: StreamingTranscriptionClient?
    private(set) var sampleRate: Int?
    /// Apple lanes: the SpeechAnalyzer session fed with converted buffers.
    private(set) var appleSession: AppleLiveSessionBox?
    private(set) var appleConverter: AppleSpeechAudioConverterBox?

    private var accumulated = TranscriptAccumulator(shape: .cumulativeTranscript)
    private var firstPartialAt: Date?
    private var abandoned = false

    init(candidate: ComparisonCandidate) {
        self.candidate = candidate
        entry = ModelComparisonEntry(
            modelID: candidate.modelID,
            modelDisplayName: candidate.displayName,
            providerDisplayName: candidate.providerDisplayName
        )
    }

    var isOpen: Bool { entry.errorDescription == nil && (client != nil || appleSession != nil) }

    var displayText: String { entry.transcript }

    // MARK: Opening

    // swiftlint:disable:next function_parameter_count
    func openSharedClient(
        route: LiveTranscriptionRoute,
        apiKey: String,
        language: String?,
        keywords: [String],
        azureEndpoint: String,
        onTranscript: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        guard let client = LiveTranscriptionClientFactory.makeClient(
            for: route,
            apiKey: apiKey,
            language: language,
            keywords: keywords,
            azureEndpoint: azureEndpoint
        ) else {
            throw LiveTranscriptionClientError.providerNotAvailable(route.provider)
        }
        accumulated = TranscriptAccumulator(shape: client.finalShape)
        let entryID = entry.id
        client.start(
            onTranscript: onTranscript,
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.entry.id == entryID, !self.abandoned else { return }
                    self.entry.errorDescription = error.localizedDescription
                }
            }
        )
        self.client = client
        sampleRate = route.sampleRate
    }

    func openAppleSession(
        inputFormat: AVAudioFormat,
        localeIdentifier: String,
        onTranscript: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        guard #available(macOS 26.0, *) else { throw AppleLocalModelError.speechTranscriberUnavailable }
        let session = try await AppleSpeechAnalyzerLiveSession(
            localeIdentifier: localeIdentifier,
            engine: AppleSpeechAnalyzerEngine(modelID: candidate.modelID),
            assetPolicy: .installedOnly
        ) { update in
            onTranscript(update.text, update.isFinal)
        }
        let converter = try AppleSpeechAudioConverter(sourceFormat: inputFormat, targetFormat: session.audioFormat)
        appleSession = AppleLiveSessionBox(session)
        appleConverter = AppleSpeechAudioConverterBox(converter)
        // Apple restates the whole transcript on every update.
        accumulated = TranscriptAccumulator(shape: .cumulativeTranscript)
    }

    // MARK: Transcripts

    func record(text: String, isFinal: Bool) {
        guard !abandoned else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if firstPartialAt == nil {
            firstPartialAt = Date()
            entry.timeToFirstPartialMs = SessionLatencyMetrics.milliseconds(from: captureStartedAt, to: firstPartialAt)
        }
        entry.transcript = isFinal ? accumulated.append(final: trimmed) : accumulated.display(withInterim: trimmed)
    }

    /// Commits the session and waits for its full transcript.
    func finish(stoppedAt: Date) async {
        guard !abandoned else { return }
        if let appleSession {
            await finishApple(appleSession, stoppedAt: stoppedAt)
        } else if let client {
            await finishClient(client, stoppedAt: stoppedAt)
        }
        if entry.errorDescription == nil, entry.transcript.isEmpty {
            entry.errorDescription = "The model returned no transcript"
        }
    }

    private func finishClient(_ client: StreamingTranscriptionClient, stoppedAt: Date) async {
        if let finalizing = client as? FinalizingStreamingTranscriptionClient {
            // The catalogue budget is the provider's own finalisation
            // allowance; the floor covers providers that declare none.
            let seconds = max(ModelCatalog.liveCapabilities(for: candidate.modelID).postStopFinalizeBudget, 8)
            let budget = Duration.seconds(seconds)
            if let transcript = await Self.withTimeout(budget, operation: { await finalizing.finishAndWait() }) {
                accumulated.replace(with: transcript)
                entry.transcript = accumulated.text
            }
        } else {
            client.stop()
        }
        entry.timeToFinalMs = SessionLatencyMetrics.milliseconds(from: stoppedAt, to: Date())
        self.client = nil
    }

    private func finishApple(_ box: AppleLiveSessionBox, stoppedAt: Date) async {
        do {
            let result = try await box.finish()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                accumulated.replace(with: text)
                entry.transcript = accumulated.text
            }
        } catch {
            if entry.transcript.isEmpty {
                entry.errorDescription = error.localizedDescription
            }
        }
        entry.timeToFinalMs = SessionLatencyMetrics.milliseconds(from: stoppedAt, to: Date())
        appleSession = nil
    }

    func abandon() {
        abandoned = true
        client?.stop()
        client = nil
        if let appleSession {
            Task { await appleSession.cancel() }
        }
        appleSession = nil
    }

    /// Runs `operation` and gives up after `budget`, so one provider that
    /// never answers cannot hold every other lane's result hostage.
    private static func withTimeout<T: Sendable>(
        _ budget: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            defer { group.cancelAll() }
            if let first = await group.next() { return first }
            return nil
        }
    }
}

/// Erases the OS-26 availability of the Apple live session so the lane can
/// hold one on every deployment target.
final class AppleLiveSessionBox: @unchecked Sendable {
    private let sendHandler: @Sendable (AVAudioPCMBuffer) -> Void
    private let finishHandler: @Sendable () async throws -> TranscriptionResult
    private let cancelHandler: @Sendable () async -> Void

    @available(macOS 26.0, *)
    init(_ session: AppleSpeechAnalyzerLiveSession) {
        sendHandler = { session.send($0) }
        finishHandler = { try await session.finish() }
        cancelHandler = { await session.cancel() }
    }

    func send(_ buffer: AVAudioPCMBuffer) { sendHandler(buffer) }
    func finish() async throws -> TranscriptionResult { try await finishHandler() }
    func cancel() async { await cancelHandler() }
}

final class AppleSpeechAudioConverterBox: @unchecked Sendable {
    private let convertHandler: @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer?

    @available(macOS 26.0, *)
    init(_ converter: AppleSpeechAudioConverter) {
        convertHandler = { converter.convert($0) }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? { convertHandler(buffer) }
}
