import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class PronunciationSSMLDelegationTests: XCTestCase {
    @MainActor
    func testMacManager_UsesPortableRendererIncludingEscapingAndProtectedPhonemes() throws {
        let suite = "PronunciationSSMLDelegationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PronunciationManager(defaults: defaults)
        let entries = [
            PronunciationEntry(word: "Token", pronunciation: #"$1\&"'<>ipa"#),
            PronunciationEntry(word: "ipa", pronunciation: "wrong", caseSensitive: true),
            PronunciationEntry(word: "phoneme", pronunciation: "wrong", caseSensitive: true),
            PronunciationEntry(word: "(猫)(12)", pronunciation: "x", replacement: "<$2&$1>", isRegex: true)
        ]
        try manager.importFromJSON(JSONEncoder().encode(entries), merge: false)
        let text = "TOKEN & 猫12"
        let expected = #"<phoneme alphabet="ipa" ph="$1\&amp;&quot;&apos;&lt;&gt;ipa">Token</phoneme>"#
            + " &amp; &lt;12&amp;猫&gt;"
        XCTAssertEqual(manager.generateSSML(for: text, provider: PronunciationPhonemeCapability.ipa), expected)
        XCTAssertEqual(PronunciationRenderer().generateSSML(
            for: text, entries: entries, provider: PronunciationPhonemeCapability.ipa), expected)
        XCTAssertEqual(manager.entries, entries)
    }

    @MainActor
    func testMacManager_AuthoredTagsAndEntitiesPassThroughButUnsupportedProviderKeepsOrdinaryReplacements() throws {
        let suite = "PronunciationSSMLDelegationTests.authored.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PronunciationManager(defaults: defaults)
        let entries = ["Token", "speak", "phoneme", "ipa", "prosody", "amp"].map {
            PronunciationEntry(word: $0, pronunciation: "must-not-rewrite", replacement: "changed", caseSensitive: true)
        }
        try manager.importFromJSON(JSONEncoder().encode(entries), merge: false)
        let authored = [
            " \n<speak>Token &amp; text</speak>",
            "<prosody rate='slow'>Token</prosody>",
            "Token <phoneme alphabet='ipa' ph='Token'>Token</phoneme>",
            "Token &amp; text", "Token &#38; text", "Token &#x26; text",
            "&lt;speak&gt;Token&lt;/speak&gt;", "Token &unknown; text"
        ]
        for text in authored {
            let actual = manager.generateSSML(for: text, provider: PronunciationPhonemeCapability.ipa)
            XCTAssertEqual(actual, text)
            XCTAssertEqual(Data(actual.utf8), Data(text.utf8))
            XCTAssertEqual(manager.generateSSML(
                for: text, provider: PronunciationPhonemeCapability.unsupported),
                           manager.applyReplacements(to: text))
        }
        let document = "<speak>Token &amp;</speak>"
        XCTAssertNotEqual(manager.generateSSML(
            for: document, provider: PronunciationPhonemeCapability.unsupported), document)
        XCTAssertNotEqual(PronunciationRenderer().generateSSML(
            for: document, entries: entries, provider: PronunciationPhonemeCapability.ipa), document,
                          "The direct renderer remains a plain-text API; entrypoints detect authored XML.")
        XCTAssertEqual(manager.entries, entries)
    }
}
