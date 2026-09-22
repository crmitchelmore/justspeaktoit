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

    private static func entry(_ rule: PronunciationParityFixture.Rule) -> PronunciationEntry {
        PronunciationEntry(
            word: rule.word, pronunciation: rule.pronunciation, replacement: rule.replacement,
            isRegex: rule.isRegex, caseSensitive: rule.caseSensitive
        )
    }
}
