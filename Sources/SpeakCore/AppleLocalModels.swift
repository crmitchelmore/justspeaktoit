import AVFoundation
import CoreMedia
import Foundation
import Speech

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleLocalModels {
    public static let legacySpeechModelID = "apple/local/SFSpeechRecognizer"
    public static let speechTranscriberModelID = "apple/local/SpeechTranscriber"
    public static let foundationModelID = "apple/local/FoundationModels"

    public static var supportsSpeechTranscriber: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    public static var preferredSpeechModelID: String {
        preferredSpeechModelID(speechTranscriberAvailable: supportsSpeechTranscriber)
    }

    public static func preferredSpeechModelID(speechTranscriberAvailable: Bool) -> String {
        speechTranscriberAvailable ? speechTranscriberModelID : legacySpeechModelID
    }

    public static var supportsFoundationModels: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public static func isAppleSpeechModel(_ modelID: String) -> Bool {
        modelID == legacySpeechModelID || modelID == speechTranscriberModelID
    }
}

public enum AppleLocalModelError: LocalizedError {
    case speechTranscriberUnavailable
    case localeUnsupported(String)
    case modelAssetsUnavailable
    case compatibleAudioFormatUnavailable
    case foundationModelUnavailable
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .speechTranscriberUnavailable:
            return "Apple SpeechTranscriber isn't available on this device."
        case .localeUnsupported(let identifier):
            return "Apple SpeechTranscriber doesn't support the \(identifier) locale on this device."
        case .modelAssetsUnavailable:
            return "Apple's on-device speech model could not be installed."
        case .compatibleAudioFormatUnavailable:
            return "Apple SpeechTranscriber could not provide a compatible audio format."
        case .foundationModelUnavailable:
            return "Apple Intelligence's on-device language model isn't available on this device."
        case .emptyTranscript:
            return "Apple SpeechTranscriber returned an empty transcript."
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
public enum AppleSpeechAnalyzerTranscriber {
    public static func transcribeFile(
        at url: URL,
        localeIdentifier: String?
    ) async throws -> TranscriptionResult {
        let transcriber = try await makeTranscriber(
            localeIdentifier: localeIdentifier,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        let duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0

        async let collectedSegments = collectFinalSegments(from: transcriber)
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let segments = try await collectedSegments
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppleLocalModelError.emptyTranscript }

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: averageConfidence(in: segments),
            duration: duration,
            modelIdentifier: AppleLocalModels.speechTranscriberModelID,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    static func makeTranscriber(
        localeIdentifier: String?,
        preset: SpeechTranscriber.Preset
    ) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw AppleLocalModelError.speechTranscriberUnavailable
        }

        let requestedLocale = Locale(identifier: localeIdentifier ?? Locale.current.identifier)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleLocalModelError.localeUnsupported(requestedLocale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: preset)
        try await ensureAssets(for: transcriber)
        return transcriber
    }

    private static func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard try await waitForInstalledAssets(for: transcriber) else {
                throw AppleLocalModelError.modelAssetsUnavailable
            }
        case .unsupported:
            throw AppleLocalModelError.modelAssetsUnavailable
        @unknown default:
            throw AppleLocalModelError.modelAssetsUnavailable
        }
    }

    private static func waitForInstalledAssets(for transcriber: SpeechTranscriber) async throws -> Bool {
        for _ in 0 ..< 120 {
            try Task.checkCancellation()
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed:
                return true
            case .downloading:
                try await Task.sleep(for: .milliseconds(250))
            case .supported, .unsupported:
                return false
            @unknown default:
                return false
            }
        }
        return false
    }

    private static func collectFinalSegments(
        from transcriber: SpeechTranscriber
    ) async throws -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let segment = makeSegment(from: result, isFinal: true)
            guard !segment.text.isEmpty else { continue }
            segments.append(segment)
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }

    static func makeSegment(
        from result: SpeechTranscriber.Result,
        isFinal: Bool
    ) -> TranscriptionSegment {
        let start = max(0, result.range.start.seconds)
        let duration = max(0, result.range.duration.seconds)
        return TranscriptionSegment(
            startTime: start.isFinite ? start : 0,
            endTime: start.isFinite && duration.isFinite ? start + duration : 0,
            text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: isFinal,
            confidence: nil
        )
    }

    static func averageConfidence(in segments: [TranscriptionSegment]) -> Double? {
        let values = segments.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

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
        onUpdate: @escaping @Sendable (AppleSpeechAnalyzerUpdate) -> Void
    ) async throws {
        let transcriber = try await AppleSpeechAnalyzerTranscriber.makeTranscriber(
            localeIdentifier: localeIdentifier,
            preset: .timeIndexedProgressiveTranscription
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.audioFormat = format
        self.analyzer = analyzer
        self.inputContinuation = continuation
        self.resultTask = Self.makeResultTask(transcriber: transcriber, onUpdate: onUpdate)

        try await analyzer.start(inputSequence: inputSequence)
    }

    private static func makeResultTask(
        transcriber: SpeechTranscriber,
        onUpdate: @escaping @Sendable (AppleSpeechAnalyzerUpdate) -> Void
    ) -> Task<TranscriptionResult, Error> {
        Task {
            var finalSegments: [TranscriptionSegment] = []
            var volatileSegment: TranscriptionSegment?

            for try await result in transcriber.results {
                let segment = AppleSpeechAnalyzerTranscriber.makeSegment(
                    from: result,
                    isFinal: result.isFinal
                )
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
                modelIdentifier: AppleLocalModels.speechTranscriberModelID,
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
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultTask.value
    }

    public func cancel() async {
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultTask.cancel()
    }
}

@available(macOS 26.0, iOS 26.0, *)
public final class AppleSpeechAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()

    public init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else { return nil }
        guard output.frameLength > 0 else { return nil }
        return output
    }
}

public enum AppleFoundationModelPolisher {
    public static var isAvailable: Bool {
        AppleLocalModels.supportsFoundationModels
    }

    public static func process(text: String, systemPrompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw AppleLocalModelError.foundationModelUnavailable
            }
            let session = LanguageModelSession(instructions: systemPrompt)
            let response = try await session.respond(
                to: "Clean this raw transcript and return only the cleaned text:\n\n\(text)"
            )
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw AppleLocalModelError.foundationModelUnavailable
    }
}
