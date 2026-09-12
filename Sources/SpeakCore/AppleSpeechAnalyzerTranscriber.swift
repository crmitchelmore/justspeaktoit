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
enum AppleSpeechAnalyzerModule: Sendable {
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

/// Result fields shared by every SpeechAnalyzer module the app uses.
@available(macOS 26.0, iOS 26.0, *)
struct AppleSpeechAnalyzerModuleResult: Sendable {
    let text: String
    let startSeconds: Double
    let durationSeconds: Double
    let isFinal: Bool
}

@available(macOS 26.0, iOS 26.0, *)
struct AppleSpeechAnalyzerModuleConfiguration: Sendable {
    let engine: AppleSpeechAnalyzerEngine
    let module: AppleSpeechAnalyzerModule
    let localeIdentifier: String
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
    /// and applying the requested asset policy. `progressive` selects presets
    /// that report volatile partial results for live streaming.
    static func makeModule(
        engine: AppleSpeechAnalyzerEngine,
        localeIdentifier: String?,
        progressive: Bool,
        assetPolicy: AppleSpeechAssetPolicy = .installIfNeeded
    ) async throws -> AppleSpeechAnalyzerModuleConfiguration {
        let configuration: AppleSpeechAnalyzerModuleConfiguration
        if assetPolicy == .installedOnly {
            configuration = try await AppleSpeechDependencyWait.run(
                timeout: AppleSpeechDependencyWait.inventoryTimeout
            ) {
                try await resolveModule(engine: engine, localeIdentifier: localeIdentifier, progressive: progressive)
            }
        } else {
            configuration = try await resolveModule(
                engine: engine, localeIdentifier: localeIdentifier, progressive: progressive
            )
        }
        try await ensureAssets(for: [configuration.module.speechModule], policy: assetPolicy)
        return configuration
    }

    /// Resolves the same engine, locale and preset for preparation and capture, without installing.
    static func resolveModule(
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

        try Task.checkCancellation()
        let resolvedEngine = AppleSpeechAnalyzerEngine(modelID: route.modelID)
        switch resolvedEngine {
        case .speechTranscriber:
            let transcriber = SpeechTranscriber(
                locale: route.value,
                preset: progressive
                    ? .timeIndexedProgressiveTranscription
                    : .timeIndexedTranscriptionWithAlternatives
            )
            return AppleSpeechAnalyzerModuleConfiguration(
                engine: resolvedEngine,
                module: .speech(transcriber),
                localeIdentifier: route.value.identifier
            )

        case .dictationTranscriber:
            // The progressive preset lacks time indexing; add it so segment
            // ordering and durations match the SpeechTranscriber presets.
            var preset: DictationTranscriber.Preset = progressive
                ? .progressiveLongDictation
                : .timeIndexedLongDictation
            preset.attributeOptions.insert(.audioTimeRange)
            let transcriber = DictationTranscriber(locale: route.value, preset: preset)
            return AppleSpeechAnalyzerModuleConfiguration(
                engine: resolvedEngine,
                module: .dictation(transcriber),
                localeIdentifier: route.value.identifier
            )
        }
    }

    static func ensureAssets(
        for modules: [any SpeechModule],
        policy: AppleSpeechAssetPolicy = .installIfNeeded,
        onPreparing: @Sendable () async -> Void = {},
        inventoryTimeout: Duration? = nil
    ) async throws {
        try await AppleSpeechAssets.ensure(
            policy: policy,
            status: { AppleSpeechAssetStatus(await AssetInventory.status(forModules: modules)) },
            install: {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                    return false
                }
                try Task.checkCancellation()
                try await request.downloadAndInstall()
                return true
            },
            onPreparing: onPreparing,
            inventoryTimeout: inventoryTimeout
        )
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
