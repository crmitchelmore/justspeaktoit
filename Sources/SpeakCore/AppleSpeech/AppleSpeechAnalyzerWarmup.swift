import AVFoundation
import Foundation
import Speech

/// Keeps resolved setups across recordings. Only successful resolutions are
/// stored; a caller that later finds a cached setup unusable removes it.
final class AppleSpeechAnalyzerSetupCache<Key: Hashable & Sendable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    func value(for key: Key, resolve: () async throws -> Value) async throws -> Value {
        if let cached = cachedValue(for: key) { return cached }
        let value = try await resolve()
        lock.withLock { values[key] = value }
        return value
    }

    func cachedValue(for key: Key) -> Value? {
        lock.withLock { values[key] }
    }

    func remove(_ key: Key) {
        lock.withLock { values[key] = nil }
    }
}

/// Resolves a live SpeechAnalyzer setup once per engine and locale (#614).
///
/// Each cold start used to re-query locale support, the asset inventory and
/// the best audio format, then load the model only when the first buffer
/// arrived, and the default `.whileInUse` retention unloaded it again after
/// every recording. The live path now reuses the resolved setup, retains the
/// model between recordings and loads it before analysis starts.
@available(macOS 26.0, iOS 26.0, *)
enum AppleSpeechAnalyzerLiveSetup {
    struct Key: Hashable, Sendable {
        let engine: AppleSpeechAnalyzerEngine
        let localeIdentifier: String
    }

    struct Resolved: @unchecked Sendable {
        let engine: AppleSpeechAnalyzerEngine
        let locale: Locale
        let format: AVAudioFormat
    }

    struct Setup {
        let key: Key
        let configuration: AppleSpeechAnalyzerModuleConfiguration
        let format: AVAudioFormat
    }

    static let cache = AppleSpeechAnalyzerSetupCache<Key, Resolved>()

    /// The Mac records many short dictations, so the model stays loaded for the
    /// app's lifetime; iOS lets it linger briefly to bound memory.
    static var modelRetention: SpeechAnalyzer.Options.ModelRetention {
        #if os(macOS)
        return .processLifetime
        #else
        return .lingering
        #endif
    }

    static var analyzerOptions: SpeechAnalyzer.Options {
        SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: modelRetention)
    }

    static func key(engine: AppleSpeechAnalyzerEngine, localeIdentifier: String?) -> Key {
        Key(engine: engine, localeIdentifier: localeIdentifier ?? Locale.current.identifier)
    }

    static func resolve(
        engine: AppleSpeechAnalyzerEngine,
        localeIdentifier: String?,
        assetPolicy: AppleSpeechAssetPolicy
    ) async throws -> Setup {
        let key = key(engine: engine, localeIdentifier: localeIdentifier)
        let resolved = try await cache.value(for: key) {
            let configuration = try await AppleSpeechAnalyzerTranscriber.makeModule(
                engine: engine,
                localeIdentifier: localeIdentifier,
                progressive: true,
                assetPolicy: assetPolicy
            )
            try Task.checkCancellation()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [configuration.module.speechModule]
            ) else {
                throw AppleLocalModelError.compatibleAudioFormatUnavailable
            }
            return Resolved(engine: configuration.engine, locale: configuration.locale, format: format)
        }
        let configuration = AppleSpeechAnalyzerTranscriber.makeConfiguration(
            engine: resolved.engine,
            locale: resolved.locale,
            progressive: true
        )
        return Setup(key: key, configuration: configuration, format: resolved.format)
    }
}

@available(macOS 26.0, iOS 26.0, *)
public enum AppleSpeechAnalyzerWarmup {
    /// Resolves the live setup and loads the model before the next recording.
    /// Uses installed assets only: it never downloads and never opens audio.
    public static func prewarm(engine: AppleSpeechAnalyzerEngine, localeIdentifier: String?) async throws {
        let setup = try await AppleSpeechAnalyzerLiveSetup.resolve(
            engine: engine,
            localeIdentifier: localeIdentifier,
            assetPolicy: .installedOnly
        )
        let analyzer = SpeechAnalyzer(
            modules: [setup.configuration.module.speechModule],
            options: AppleSpeechAnalyzerLiveSetup.analyzerOptions
        )
        let cancellation = SpeechAnalyzerCancellation(analyzer: analyzer)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await analyzer.prepareToAnalyze(in: setup.format)
            } onCancel: {
                cancellation.start()
            }
        } catch {
            if !(error is CancellationError) {
                AppleSpeechAnalyzerLiveSetup.cache.remove(setup.key)
            }
            await cancellation.finish()
            throw error
        }
        await cancellation.finish()
    }
}
