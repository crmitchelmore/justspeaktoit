import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// The dictionary manager now delegates its replacements to the shared
/// renderer. Both must keep the outputs captured from the manager before the
/// extraction, including its SSML path.
final class PronunciationRendererParityTests: XCTestCase {
    private struct IPAProvider: PronunciationPhonemeCapable {
        let supportsSSMLPhonemes = true
        let phonemeAlphabet = "ipa"
    }

    private struct PlainProvider: PronunciationPhonemeCapable {
        let supportsSSMLPhonemes = false
        let phonemeAlphabet = "ipa"
    }

    @MainActor
    func testManagerAndRenderer_MatchOutputsCapturedBeforeExtraction() throws {
        let suite = "PronunciationRendererParityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PronunciationManager(defaults: defaults)
        let entries = PronunciationParityFixture.rules.map(Self.entry)
        try manager.importFromJSON(JSONEncoder().encode(entries), merge: false)
        XCTAssertEqual(manager.entries, entries)

        let renderer = PronunciationRenderer()
        for sample in PronunciationParityFixture.samples {
            XCTAssertEqual(manager.applyReplacements(to: sample.input), sample.replaced, sample.input)
            XCTAssertEqual(
                renderer.applyReplacements(to: sample.input, entries: entries), sample.replaced, sample.input
            )
            XCTAssertEqual(manager.generateSSML(for: sample.input, provider: IPAProvider()), sample.ssml, sample.input)
            XCTAssertEqual(
                manager.generateSSML(for: sample.input, provider: PlainProvider()), sample.replaced, sample.input
            )
        }
    }

    /// A dictionary larger than any small fixed cache stays compiled across
    /// utterances, on both the plain and SSML paths, as the manager always did.
    @MainActor
    func testManager_KeepsALargeDictionaryWarmAcrossUtterances() throws {
        let suite = "PronunciationRendererParityTests.large.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PronunciationManager(defaults: defaults)
        let entries = (0..<600).map {
            PronunciationEntry(word: "w\($0)", pronunciation: "p\($0)", replacement: "r\($0)")
        } + (0..<100).map {
            PronunciationEntry(word: "\\bz\($0)_(\\d+)\\b", pronunciation: "x", replacement: "y\($0)-$1", isRegex: true)
        }
        try manager.importFromJSON(JSONEncoder().encode(entries), merge: false)
        XCTAssertEqual(manager.entries.count, 700)

        let text = "w1 then w599 and z42_7"
        XCTAssertEqual(manager.applyReplacements(to: text), "r1 then r599 and y42-7")
        XCTAssertEqual(manager.renderer.compilationCount, 700)
        for _ in 0..<5 {
            XCTAssertEqual(manager.applyReplacements(to: text), "r1 then r599 and y42-7")
            _ = manager.generateSSML(for: text, provider: IPAProvider())
        }
        XCTAssertEqual(manager.renderer.compilationCount, 700, "A warm utterance recompiled the dictionary")
        XCTAssertEqual(manager.renderer.cachedExpressionCount, 700)
    }

    private static func entry(_ rule: PronunciationParityFixture.Rule) -> PronunciationEntry {
        PronunciationEntry(
            word: rule.word, pronunciation: rule.pronunciation, replacement: rule.replacement,
            isRegex: rule.isRegex, caseSensitive: rule.caseSensitive
        )
    }
}
