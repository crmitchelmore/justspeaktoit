import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, iOS 26.0, *)
public struct AppleSpeechAnalyzerUpdate: Sendable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?

    public init(text: String, isFinal: Bool, confidence: Double?) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

@available(macOS 26.0, iOS 26.0, *)
public final class AppleSpeechAnalyzerLiveSession: @unchecked Sendable {
    public let audioFormat: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let cancellation: SpeechAnalyzerCancellation
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let resultTask: Task<TranscriptionResult, Error>

    public init(
        localeIdentifier: String?,
        engine: AppleSpeechAnalyzerEngine = .speechTranscriber,
        onUpdate: @escaping @Sendable (AppleSpeechAnalyzerUpdate) -> Void
    ) async throws {
        try Task.checkCancellation()
        let configuration = try await AppleSpeechAnalyzerTranscriber.makeModule(
            engine: engine,
            localeIdentifier: localeIdentifier,
            progressive: true
        )
        try Task.checkCancellation()
        let module = configuration.module
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module.speechModule]
        ) else {
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }

        try Task.checkCancellation()
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        let cancellation = SpeechAnalyzerCancellation(analyzer: analyzer)
        self.cancellation = cancellation
        self.audioFormat = format
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.resultTask = Self.makeResultTask(
            results: module.resultStream(),
            engine: configuration.engine,
            onUpdate: onUpdate
        )

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await analyzer.start(inputSequence: inputSequence)
                try Task.checkCancellation()
            } onCancel: {
                continuation.finish()
                cancellation.start()
            }
        } catch {
            // The result task is already consuming the module stream — leaving it
            // running would strand it on a stream that never finishes.
            continuation.finish()
            await cancellation.finish()
            self.resultTask.cancel()
            throw error
        }
    }

    private static func makeResultTask(
        results: AsyncThrowingStream<AppleSpeechAnalyzerModuleResult, Error>,
        engine: AppleSpeechAnalyzerEngine,
        onUpdate: @escaping @Sendable (AppleSpeechAnalyzerUpdate) -> Void
    ) -> Task<TranscriptionResult, Error> {
        Task {
            var finalSegments: [TranscriptionSegment] = []
            var volatileSegment: TranscriptionSegment?

            for try await result in results {
                let segment = AppleSpeechAnalyzerTranscriber.makeSegment(from: result)
                guard !segment.text.isEmpty else { continue }

                if result.isFinal {
                    finalSegments.append(segment)
                    finalSegments.sort { $0.startTime < $1.startTime }
                    volatileSegment = nil
                } else {
                    volatileSegment = segment
                }

                let displayedSegments = finalSegments + [volatileSegment].compactMap { $0 }
                let text = displayedSegments.map(\.text).joined(separator: " ")
                onUpdate(
                    AppleSpeechAnalyzerUpdate(
                        text: text,
                        isFinal: result.isFinal,
                        confidence: AppleSpeechAnalyzerTranscriber.averageConfidence(in: displayedSegments)
                    )
                )
            }

            let text = finalSegments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = finalSegments.map(\.endTime).max() ?? 0
            return TranscriptionResult(
                text: text,
                segments: finalSegments,
                confidence: AppleSpeechAnalyzerTranscriber.averageConfidence(in: finalSegments),
                duration: duration,
                modelIdentifier: engine.modelID,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }
    }

    public func send(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async throws -> TranscriptionResult {
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultTask.value
        } catch {
            await cancellation.finish()
            resultTask.cancel()
            throw error
        }
    }

    public func cancel() async {
        inputContinuation.finish()
        await cancellation.finish()
        resultTask.cancel()
    }
}

/// A cancellation handler cannot await. Retain its one teardown task so the
/// initializer's catch and every later cancel join the same native operation.
@available(macOS 26.0, iOS 26.0, *)
private final class SpeechAnalyzerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let analyzer: SpeechAnalyzer
    private var task: Task<Void, Never>?

    init(analyzer: SpeechAnalyzer) {
        self.analyzer = analyzer
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task { return task }
        let pending = Task { await self.analyzer.cancelAndFinishNow() }
        task = pending
        return pending
    }

    func finish() async {
        await start().value
    }
}
