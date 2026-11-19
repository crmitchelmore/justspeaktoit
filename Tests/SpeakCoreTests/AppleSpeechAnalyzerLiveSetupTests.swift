import Speech
import XCTest
@testable import SpeakCore

final class AppleSpeechAnalyzerLiveSetupTests: XCTestCase {
    private struct ResolveFailure: Error {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
    }

    func testCache_ResolvesOncePerKeySoLaterStartsSkipTheQueries() async throws {
        let cache = AppleSpeechAnalyzerSetupCache<String, Int>()
        let resolves = Counter()

        let first = try await cache.value(for: "en_GB") { resolves.increment(); return 1 }
        let second = try await cache.value(for: "en_GB") { resolves.increment(); return 2 }
        let other = try await cache.value(for: "fr_FR") { resolves.increment(); return 3 }

        XCTAssertEqual([first, second, other], [1, 1, 3])
        XCTAssertEqual(resolves.value, 2)
    }

    func testCache_DoesNotKeepFailuresAndRemoveForcesAFreshResolve() async throws {
        let cache = AppleSpeechAnalyzerSetupCache<String, Int>()

        do {
            _ = try await cache.value(for: "en_GB") { throw ResolveFailure() }
            XCTFail("expected the failure to propagate")
        } catch is ResolveFailure {}
        XCTAssertNil(cache.cachedValue(for: "en_GB"))

        _ = try await cache.value(for: "en_GB") { 1 }
        cache.remove("en_GB")
        let refreshed = try await cache.value(for: "en_GB") { 2 }
        XCTAssertEqual(refreshed, 2)
    }

    func testLiveAnalyzerOptions_RetainTheModelBetweenRecordings() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires OS 26") }
        #if os(macOS)
        XCTAssertEqual(AppleSpeechAnalyzerLiveSetup.modelRetention, .processLifetime)
        #else
        XCTAssertEqual(AppleSpeechAnalyzerLiveSetup.modelRetention, .lingering)
        #endif
        let options = AppleSpeechAnalyzerLiveSetup.analyzerOptions
        XCTAssertEqual(options.modelRetention, AppleSpeechAnalyzerLiveSetup.modelRetention)
        XCTAssertEqual(options.priority, .userInitiated)
    }

    func testLivePresets_ReportVolatileResultsWithTimeRanges() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires OS 26") }
        let speech = AppleSpeechAnalyzerTranscriber.speechTranscriberPreset(progressive: true)
        XCTAssertTrue(speech.reportingOptions.isSuperset(of: [.volatileResults, .fastResults]))
        XCTAssertTrue(speech.attributeOptions.contains(.audioTimeRange))

        let dictation = AppleSpeechAnalyzerTranscriber.dictationTranscriberPreset(progressive: true)
        XCTAssertTrue(dictation.reportingOptions.contains(.volatileResults))
        XCTAssertTrue(dictation.attributeOptions.contains(.audioTimeRange))

        let batch = AppleSpeechAnalyzerTranscriber.speechTranscriberPreset(progressive: false)
        XCTAssertFalse(batch.reportingOptions.contains(.volatileResults))
    }

    func testSetupKey_DefaultsToTheCurrentLocale() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires OS 26") }
        let key = AppleSpeechAnalyzerLiveSetup.key(engine: .speechTranscriber, localeIdentifier: nil)
        XCTAssertEqual(key.localeIdentifier, Locale.current.identifier)
        XCTAssertNotEqual(
            key,
            AppleSpeechAnalyzerLiveSetup.key(engine: .dictationTranscriber, localeIdentifier: nil)
        )
    }
}
