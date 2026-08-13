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
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let resultTask: Task<TranscriptionResult, Error>

    public init(
        localeIdentifier: String?,
        engine: AppleSpeechAnalyzerEngine = .speechTranscriber,
        onUpdate: @escaping @Sendable (AppleSpeechAnalyzerUpdate) -> Void
    ) async throws {
        let module = try await AppleSpeechAnalyzerTranscriber.makeModule(
            engine: engine,
            localeIdentifier: localeIdentifier,
            progressive: true
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module.speechModule]
        ) else {
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        self.audioFormat = format
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.resultTask = Self.makeResultTask(
            results: module.resultStream(),
            engine: engine,
            onUpdate: onUpdate
        )

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            // The result task is already consuming the module stream — leaving it
            // running would strand it on a stream that never finishes.
            continuation.finish()
            await analyzer.cancelAndFinishNow()
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
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            throw error
        }
    }

    public func cancel() async {
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultTask.cancel()
    }
}
