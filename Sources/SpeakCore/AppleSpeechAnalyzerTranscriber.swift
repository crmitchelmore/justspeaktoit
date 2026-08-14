// SpeechAnalyzer (OS 26+) transcription: engine selection, module
// abstraction, batch file transcription, and the live streaming session.
// Model id constants and availability checks live in AppleLocalModels.swift.
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// The SpeechAnalyzer module a `apple/local/...` analyzer model id maps onto.
@available(macOS 26.0, iOS 26.0, *)
public enum AppleSpeechAnalyzerEngine: Sendable, Equatable {
    /// `SpeechTranscriber` — Apple's highest-accuracy long-form module;
    /// requires an Apple Intelligence-capable device.
    case speechTranscriber
    /// `DictationTranscriber` — the keyboard-dictation module available on
    /// every OS 26 device.
    case dictationTranscriber

    public init(modelID: String) {
        self = modelID == AppleLocalModels.dictationTranscriberModelID
            ? .dictationTranscriber
            : .speechTranscriber
    }

    public var modelID: String {
        switch self {
        case .speechTranscriber: return AppleLocalModels.speechTranscriberModelID
        case .dictationTranscriber: return AppleLocalModels.dictationTranscriberModelID
        }
    }
}

/// A SpeechAnalyzer module wrapped so the transcription pipeline can treat
/// `SpeechTranscriber` and `DictationTranscriber` interchangeably.
@available(macOS 26.0, iOS 26.0, *)
enum AppleSpeechAnalyzerModule {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var speechModule: any SpeechModule {
        switch self {
        case .speech(let module): return module
        case .dictation(let module): return module
        }
    }

    /// Bridges either module's opaque result sequence into one shared stream.
    func resultStream() -> AsyncThrowingStream<AppleSpeechAnalyzerModuleResult, Error> {
        switch self {
        case .speech(let module):
            return Self.stream(module.results) { result in
                AppleSpeechAnalyzerModuleResult(
                    text: String(result.text.characters),
                    startSeconds: result.range.start.seconds,
                    durationSeconds: result.range.duration.seconds,
                    isFinal: result.isFinal
                )
            }
        case .dictation(let module):
            return Self.stream(module.results) { result in
                AppleSpeechAnalyzerModuleResult(
                    text: String(result.text.characters),
                    startSeconds: result.range.start.seconds,
                    durationSeconds: result.range.duration.seconds,
                    isFinal: result.isFinal
                )
            }
        }
    }

    private static func stream<Results: AsyncSequence & Sendable>(
        _ results: Results,
        transform: @escaping @Sendable (Results.Element) -> AppleSpeechAnalyzerModuleResult
    ) -> AsyncThrowingStream<AppleSpeechAnalyzerModuleResult, Error> where Results.Element: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in results {
                        continuation.yield(transform(element))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The asset-inventory states the install wait reacts to, mirrored off
/// `AssetInventory.Status` so the wait policy stays testable on any OS.
enum AppleSpeechAssetStatus: Sendable, Equatable {
    case unsupported
    case supported
    case downloading
    case installed
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleSpeechAssetStatus {
    init(_ status: AssetInventory.Status) {
        switch status {
        case .unsupported: self = .unsupported
        case .supported: self = .supported
        case .downloading: self = .downloading
        case .installed: self = .installed
        @unknown default: self = .unsupported
        }
    }
}

/// What the asset-install wait loop should do after one inventory poll.
enum AppleSpeechAssetWaitStep: Sendable, Equatable {
    case installed
    case keepWaiting
    case giveUp
}

/// How long the SpeechAnalyzer asset wait tolerates each inventory state.
///
/// `.downloading` gets the full budget because a cold model download is slow.
/// `.supported` means "installable but not installing", which only resolves
/// itself while an install request is in flight — so it gets a short grace
/// window when one was issued, and no wait at all when none was, instead of
/// silently consuming the whole download budget before failing.
enum AppleSpeechAssetWaitPolicy {
    static let pollInterval = Duration.milliseconds(250)
    /// 120 × 250ms = 30s.
    static let maxPolls = 120
    /// 8 × 250ms = 2s.
    static let supportedGracePolls = 8

    static func step(
        status: AppleSpeechAssetStatus,
        didRequestInstall: Bool,
        consecutiveSupportedPolls: Int
    ) -> AppleSpeechAssetWaitStep {
        switch status {
        case .installed:
            return .installed
        case .downloading:
            return .keepWaiting
        case .supported:
            guard didRequestInstall else { return .giveUp }
            return consecutiveSupportedPolls <= supportedGracePolls ? .keepWaiting : .giveUp
        case .unsupported:
            return .giveUp
        }
    }
}

/// Result fields shared by every SpeechAnalyzer module the app uses.
@available(macOS 26.0, iOS 26.0, *)
struct AppleSpeechAnalyzerModuleResult: Sendable {
    let text: String
    let startSeconds: Double
    let durationSeconds: Double
    let isFinal: Bool
}

@available(macOS 26.0, iOS 26.0, *)
struct AppleSpeechAnalyzerModuleConfiguration {
    let engine: AppleSpeechAnalyzerEngine
    let module: AppleSpeechAnalyzerModule
}

enum AppleSpeechAnalyzerRouting {
    static func resolve<Value: Sendable>(
        preferredModelID: String,
        speechTranscriberAvailable: Bool,
        supportedValue: @Sendable (String) async -> Value?
    ) async -> (modelID: String, value: Value)? {
        let alternativeModelID = preferredModelID == AppleLocalModels.dictationTranscriberModelID
            ? AppleLocalModels.speechTranscriberModelID
            : AppleLocalModels.dictationTranscriberModelID
        let candidates = [preferredModelID, alternativeModelID].filter {
            $0 != AppleLocalModels.speechTranscriberModelID || speechTranscriberAvailable
        }

        for modelID in candidates {
            if let value = await supportedValue(modelID) {
                return (modelID, value)
            }
        }
        return nil
    }
}

@available(macOS 26.0, iOS 26.0, *)
public enum AppleSpeechAnalyzerTranscriber {
    public static func transcribeFile(
        at url: URL,
        localeIdentifier: String?,
        engine: AppleSpeechAnalyzerEngine = .speechTranscriber
    ) async throws -> TranscriptionResult {
        let configuration = try await makeModule(
            engine: engine,
            localeIdentifier: localeIdentifier,
            progressive: false
        )
        let module = configuration.module
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        let audioFile = try AVAudioFile(forReading: url)
        let duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0

        async let collectedSegments = collectFinalSegments(from: module.resultStream())
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
            modelIdentifier: configuration.engine.modelID,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    /// Builds the SpeechAnalyzer module for `engine`, verifying locale support
    /// and downloading model assets when needed. `progressive` selects presets
    /// that report volatile partial results for live streaming.
    static func makeModule(
        engine: AppleSpeechAnalyzerEngine,
        localeIdentifier: String?,
        progressive: Bool
    ) async throws -> AppleSpeechAnalyzerModuleConfiguration {
        let requestedLocale = Locale(identifier: localeIdentifier ?? Locale.current.identifier)
        guard let route = await AppleSpeechAnalyzerRouting.resolve(
            preferredModelID: engine.modelID,
            speechTranscriberAvailable: SpeechTranscriber.isAvailable,
            supportedValue: { modelID in
                if modelID == AppleLocalModels.speechTranscriberModelID {
                    return await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
                }
                return await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
            }
        ) else {
            throw AppleLocalModelError.localeUnsupported(requestedLocale.identifier)
        }

        let resolvedEngine = AppleSpeechAnalyzerEngine(modelID: route.modelID)
        switch resolvedEngine {
        case .speechTranscriber:
            let transcriber = SpeechTranscriber(
                locale: route.value,
                preset: progressive
                    ? .timeIndexedProgressiveTranscription
                    : .timeIndexedTranscriptionWithAlternatives
            )
            try await ensureAssets(for: [transcriber])
            return AppleSpeechAnalyzerModuleConfiguration(
                engine: resolvedEngine,
                module: .speech(transcriber)
            )

        case .dictationTranscriber:
            // The progressive preset lacks time indexing; add it so segment
            // ordering and durations match the SpeechTranscriber presets.
            var preset: DictationTranscriber.Preset = progressive
                ? .progressiveLongDictation
                : .timeIndexedLongDictation
            preset.attributeOptions.insert(.audioTimeRange)
            let transcriber = DictationTranscriber(locale: route.value, preset: preset)
            try await ensureAssets(for: [transcriber])
            return AppleSpeechAnalyzerModuleConfiguration(
                engine: resolvedEngine,
                module: .dictation(transcriber)
            )
        }
    }

    private static func ensureAssets(for modules: [any SpeechModule]) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .supported, .downloading:
            var didRequestInstall = false
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                didRequestInstall = true
                try await request.downloadAndInstall()
            }
            guard try await waitForInstalledAssets(
                for: modules,
                didRequestInstall: didRequestInstall
            ) else {
                throw AppleLocalModelError.modelAssetsUnavailable
            }
        case .unsupported:
            throw AppleLocalModelError.modelAssetsUnavailable
        @unknown default:
            throw AppleLocalModelError.modelAssetsUnavailable
        }
    }

    /// Polls the asset inventory until the modules report `.installed`, applying
    /// `AppleSpeechAssetWaitPolicy` so a device with nothing left to download
    /// fails fast instead of burning the whole download budget.
    private static func waitForInstalledAssets(
        for modules: [any SpeechModule],
        didRequestInstall: Bool
    ) async throws -> Bool {
        var consecutiveSupportedPolls = 0
        for _ in 0 ..< AppleSpeechAssetWaitPolicy.maxPolls {
            try Task.checkCancellation()
            let status = AppleSpeechAssetStatus(await AssetInventory.status(forModules: modules))
            consecutiveSupportedPolls = status == .supported ? consecutiveSupportedPolls + 1 : 0
            switch AppleSpeechAssetWaitPolicy.step(
                status: status,
                didRequestInstall: didRequestInstall,
                consecutiveSupportedPolls: consecutiveSupportedPolls
            ) {
            case .installed:
                return true
            case .keepWaiting:
                try await Task.sleep(for: AppleSpeechAssetWaitPolicy.pollInterval)
            case .giveUp:
                return false
            }
        }
        return false
    }

    private static func collectFinalSegments(
        from results: AsyncThrowingStream<AppleSpeechAnalyzerModuleResult, Error>
    ) async throws -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        for try await result in results where result.isFinal {
            let segment = makeSegment(from: result)
            guard !segment.text.isEmpty else { continue }
            segments.append(segment)
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }

    static func makeSegment(from result: AppleSpeechAnalyzerModuleResult) -> TranscriptionSegment {
        let start = max(0, result.startSeconds)
        let duration = max(0, result.durationSeconds)
        return TranscriptionSegment(
            startTime: start.isFinite ? start : 0,
            endTime: start.isFinite && duration.isFinite ? start + duration : 0,
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: result.isFinal,
            confidence: nil
        )
    }

    static func averageConfidence(in segments: [TranscriptionSegment]) -> Double? {
        let values = segments.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
