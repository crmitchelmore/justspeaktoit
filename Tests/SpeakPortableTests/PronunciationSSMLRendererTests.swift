import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class PronunciationSSMLRendererTests: XCTestCase {
    func testPortableSSML_MatchesEntireEstablishedMacCorpusAndUnsupportedFallback() {
        let entries = PronunciationParityFixture.rules.map {
            PronunciationEntry(word: $0.word, pronunciation: $0.pronunciation, replacement: $0.replacement,
                               isRegex: $0.isRegex, caseSensitive: $0.caseSensitive)
        }
        let renderer = PronunciationRenderer(retention: .activeDictionary)
        for _ in 0..<2 {
            for sample in PronunciationParityFixture.samples {
                XCTAssertEqual(renderer.generateSSML(
                    for: sample.input, entries: entries, provider: PronunciationPhonemeCapability.ipa),
                               sample.ssml, sample.input)
                XCTAssertEqual(renderer.generateSSML(
                    for: sample.input, entries: entries, provider: PronunciationPhonemeCapability.unsupported),
                               sample.replaced, sample.input)
            }
        }
    }

    func testXMLMetacharactersAndRegexTemplateCharacters_AreLiteralInsidePhonemes() {
        struct Provider: PronunciationPhonemeCapable {
            let supportsSSMLPhonemes = true
            let phonemeAlphabet = "i&\"p'"
        }
        let entry = PronunciationEntry(
            word: #"A&<$1\B>"#, pronunciation: #"p&"'<$1\>"#, caseSensitive: true)
        let actual = PronunciationRenderer().generateSSML(
            for: #"raw & " ' < > A&<$1\B>"#, entries: [entry], provider: Provider())
        XCTAssertEqual(actual, #"raw &amp; &quot; &apos; &lt; &gt; "# +
            #"<phoneme alphabet="i&amp;&quot;p&apos;" ph="p&amp;&quot;&apos;&lt;$1\&gt;">"# +
            #"A&amp;&lt;$1\B&gt;</phoneme>"#)
        let insensitive = PronunciationEntry(word: "Token", pronunciation: #"$1\p&"#)
        XCTAssertEqual(PronunciationRenderer().generateSSML(
            for: "TOKEN", entries: [insensitive], provider: PronunciationPhonemeCapability.ipa),
                       #"<phoneme alphabet="ipa" ph="$1\p&amp;">Token</phoneme>"#)
    }

    func testLaterRules_CannotRewriteOrNestGeneratedTagsAndAnchorsDoNotRestartAtPieces() {
        let entries = [
            PronunciationEntry(word: "Token", pronunciation: "ipa", caseSensitive: true),
            PronunciationEntry(word: "ipa", pronunciation: "bad", caseSensitive: true),
            PronunciationEntry(word: "phoneme", pronunciation: "bad", caseSensitive: true),
            PronunciationEntry(word: "Token", pronunciation: "bad", caseSensitive: true),
            PronunciationEntry(word: "^ after", pronunciation: "x", replacement: "WRONG", isRegex: true),
            PronunciationEntry(word: "before $", pronunciation: "x", replacement: "WRONG", isRegex: true)
        ]
        XCTAssertEqual(PronunciationRenderer().generateSSML(
            for: "before Token after", entries: entries, provider: PronunciationPhonemeCapability.ipa),
                       #"before <phoneme alphabet="ipa" ph="ipa">Token</phoneme> after"#)
    }

    func testRegexProducedMarkup_IsEscapedTextAndOrderedRulesStillSeeRawReplacementText() {
        let entries = [
            PronunciationEntry(word: #"(猫)(\d+)"#, pronunciation: "unused",
                               replacement: #"<break ph="$2">a&$1</break>"#, isRegex: true),
            PronunciationEntry(word: "a&猫", pronunciation: "IPA", caseSensitive: true),
            PronunciationEntry(word: "删", pronunciation: "unused", replacement: "", isRegex: true)
        ]
        XCTAssertEqual(PronunciationRenderer().generateSSML(
            for: "猫12 删", entries: entries, provider: PronunciationPhonemeCapability.ipa),
                       #"&lt;break ph=&quot;12&quot;&gt;"# +
                       #"<phoneme alphabet="ipa" ph="IPA">a&amp;猫</phoneme>&lt;/break&gt; "#)
    }

    func testPhonemeCapability_IsOnlyExecutableAzureNeuralNotMAIOrOtherDesktopRoutes() {
        for voice in DesktopSpeechVoice.voices {
            if case .azureNeural = voice {
                XCTAssertTrue(voice.supportsSSMLPhonemes)
                XCTAssertEqual(voice.phonemeAlphabet, "ipa")
            } else {
                XCTAssertFalse(voice.supportsSSMLPhonemes, voice.modelID)
            }
        }
    }

    func testAuthoredMarkupIntent_DocumentsTagsAndEntityFragmentsButNotUnescapedText() {
        for text in ["<speak>Token</speak>", "before <break time='1s'/> Token",
                     "<prosody rate='slow'>Token</prosody>", "</phoneme>", "<!-- Token -->",
                     "<?xml version='1.0'?><speak/>", "<speak", "<phoneme ph='unfinished",
                     "Token &amp; text", "Token &#38; text", "Token &#x26; text", "&lt;speak&gt;",
                     "Token &unknown; text", "&custom:entity;", "<東京>", "&東京;"] {
            XCTAssertTrue(VoiceSynthesisMarkup.containsAuthoredMarkup(in: text), text)
        }
        for text in ["Token", "a < b & b > c", "1 < 2", "x <= y", "a > b",
                     "Token & text", "Token &amp", "Token &#x;"] {
            XCTAssertFalse(VoiceSynthesisMarkup.containsAuthoredMarkup(in: text), text)
        }
    }

    func testSSMLCache_RetainsCurrentDictionaryAndReusesEveryExpression() {
        let renderer = PronunciationRenderer(retention: .activeDictionary)
        let first = (0..<600).map { PronunciationEntry(word: "w\($0)", pronunciation: "p\($0)") }
            + (0..<100).map {
                PronunciationEntry(word: "z\($0)", pronunciation: "x", replacement: "r", isRegex: true)
            }
        for _ in 0..<2 {
            _ = renderer.generateSSML(for: "w1 z1", entries: first, provider: PronunciationPhonemeCapability.ipa)
            XCTAssertEqual(renderer.compilationCount, 700)
            XCTAssertEqual(renderer.cachedExpressionCount, 700)
        }
        _ = renderer.generateSSML(for: "new", entries: [.init(word: "new", pronunciation: "n")],
                                 provider: PronunciationPhonemeCapability.ipa)
        XCTAssertEqual(renderer.cachedExpressionCount, 1)
        XCTAssertEqual(renderer.compilationCount, 701)
    }
}
