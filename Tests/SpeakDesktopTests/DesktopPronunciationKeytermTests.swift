import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopPronunciationKeytermTests: XCTestCase {
    private let dictionaryKey = ApplicationPreferenceKey.ttsPronunciationDictionary.rawValue
    private let ignoredKey = ApplicationPreferenceKey.assemblyAIIgnoredPronunciationTerms.rawValue

    func testSeedPolicy_PreservesModernPriorityAndSortedLegacyOrder() {
        let seeds = AssemblyAIPronunciationKeyterms.seeds(
            modern: [" Beta ", "alpha", "BETA"],
            legacy: ["zeta", "Alpha", "", "two,terms", String(repeating: "x", count: 51)]
        )
        XCTAssertEqual(seeds, ["Beta", "alpha", "zeta"])
    }

    func testSelection_CapturesModernPrioritySuppressionAndStableLegacyOrder() {
        let selection = AssemblyAIPronunciationKeyterms.Selection(
            current: ["Explicit", "HIDDEN"], legacy: ["Zeta", "alpha"], ignored: ["hidden", "beta"]
        ).capturingModernWords(["Beta", "alpha", "Modern"])
        XCTAssertEqual(selection.keyterms, ["Explicit", "HIDDEN", "alpha", "Modern", "Zeta"])
        XCTAssertEqual(selection.capturingModernWords(["Later"]), selection)
        XCTAssertEqual(
            AssemblyAIPronunciationKeyterms.Selection(current: [], legacy: ["Zeta", "alpha"], ignored: []),
            AssemblyAIPronunciationKeyterms.Selection(current: [], legacy: ["alpha", "Zeta"], ignored: [])
        )
    }

    func testResolvedOptions_PreserveVocabularyAndControlsWithoutReopeningTheSeedSnapshot() {
        let configured = LiveClientOptions(
            keywords: ["Shared"], assemblyAIKeyterms: ["Explicit"], modulate: .init(emotionSignal: true),
            postStopFinalizeBudget: 9, stopGracePeriod: 0.3
        ).capturingPronunciationKeyterms(.init(current: ["Explicit"], legacy: ["Alpha"], ignored: []))
        let captured = configured.includingPronunciationWords(["Modern"]).includingVocabularyKeywords(["Lexicon"])
        XCTAssertEqual(captured.keywords, ["Shared", "Lexicon"])
        XCTAssertEqual(captured.assemblyAIKeyterms, ["Explicit", "Modern", "Alpha", "Lexicon"])
        XCTAssertEqual(captured.includingPronunciationWords(["Later"]), captured)
        XCTAssertEqual(captured.modulate, configured.modulate)
        XCTAssertEqual(captured.postStopFinalizeBudget, 9)
        XCTAssertEqual(captured.stopGracePeriod, 0.3)
        XCTAssertEqual(
            LiveClientOptions.desktopDefaults.includingPronunciationWords([])
                .includingPronunciationWords(["Later"]).assemblyAIKeyterms, []
        )
    }

    func testOldInitializer_ExplicitOptionsDoNotAcquireAutomaticPronunciationHints() {
        let make: ([String], [String], ModulateLiveOptions) -> LiveClientOptions
            = LiveClientOptions.init(keywords:assemblyAIKeyterms:modulate:)
        for terms in [[], ["Explicit"]] {
            let original = make(["Shared"], terms, .none)
            XCTAssertNil(original.pronunciationKeyterms)
            XCTAssertEqual(original.includingPronunciationWords(["Modern"]), original)
        }
    }

    func testCapturedModernWords_ReachTheRealAssemblyAIQueryWithoutReplacementText() throws {
        let configured = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            dictionaryKey: AnyCodable(.object(["Legacy": .string("DO NOT SEND LEGACY PRONUNCIATION")])),
            ignoredKey: AnyCodable(.array([.string("hidden")]))
        ])
        let options = configured.liveOptions.includingPronunciationWords(["Modern", "Hidden"])
        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: AssemblyAIModels.universal36ProStreamingID, apiKey: "synthetic", language: nil, azureEndpoint: "",
            options: options, makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("\($0)") })
        defer { client.cancel() }
        let request = try XCTUnwrap(factory.requests.first)
        let url = try XCTUnwrap(request.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let terms = try XCTUnwrap(items.first { $0.name == "keyterms_prompt" }?.value)
        // swiftlint:disable:next line_length
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(terms.utf8)), ["Explicit", "Modern", "Legacy"])
    }

    func testModernNativeClearAndReselection_RetainSuppressionAcrossRestart() throws {
        let original = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            ignoredKey: AnyCodable(.array([.string("unrelated")]))
        ])
        let modern = ["Modern", "two,terms", String(repeating: "x", count: 51)]
        var entries = original.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "assemblyAIKeyterms" })
        entries[index] = ""
        // swiftlint:disable:next line_length
        let cleared = try original.applying(entries).recordingPronunciationKeytermSelection(from: original, modern: modern)
        XCTAssertEqual(cleared.values[ignoredKey], AnyCodable(.array([.string("modern"), .string("unrelated")])))
        let restarted = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(cleared))
        XCTAssertEqual(restarted.liveOptions.includingPronunciationWords(modern).assemblyAIKeyterms, [])
        entries = restarted.entries
        entries[index] = "MODERN"
        let selected = try restarted.applying(entries).recordingPronunciationKeytermSelection(
            from: restarted, modern: modern
        )
        XCTAssertEqual(selected.values[ignoredKey], AnyCodable(.array([.string("unrelated")])))
        XCTAssertEqual(selected.liveOptions.includingPronunciationWords(modern).assemblyAIKeyterms, ["MODERN"])
    }

    func testSeedPolicy_UsesCharacterRatherThanUTF8ByteLimit() {
        let accepted = String(repeating: "\u{00E9}", count: 50)
        let rejected = accepted + "\u{00E9}"
        XCTAssertEqual(AssemblyAIPronunciationKeyterms.seeds(modern: [], legacy: [rejected, accepted]), [accepted])
        XCTAssertEqual(AssemblyAIPronunciationKeyterms.parse(" one, ,two,\(rejected)"), ["one", "two"])
    }

    func testMergePolicy_ExplicitTermsWinOverIgnoredSeedsAndDeduplicateCase() {
        XCTAssertEqual(AssemblyAIPronunciationKeyterms.merged(
            current: ["Explicit", "ALPHA", "explicit"], seeds: ["alpha", "Beta", "Gamma"],
            ignored: [" ALPHA ", "beta"]
        ), ["Explicit", "ALPHA", "Gamma"])
    }

    func testMergePolicy_BoundsFinalListWithoutDisplacingExplicitTerms() {
        let explicit = (0..<99).map { "Term\($0)" }
        XCTAssertEqual(AssemblyAIPronunciationKeyterms.merged(
            current: explicit, seeds: ["Last", "Overflow"], ignored: []
        ), explicit + ["Last"])
    }

    func testIgnoredPolicy_RetainsUnrelatedSuppressionAndAllowsExplicitReselection() {
        XCTAssertEqual(AssemblyAIPronunciationKeyterms.ignored(
            selected: "ALPHA", seeds: ["Alpha", "Beta"], stored: [" alpha ", "UNRELATED"]
        ), ["beta", "unrelated"])
    }

    func testLegacyDictionary_SeedsOnlyAssemblyAIAndNeverSendsPronunciationValues() throws {
        let configuration = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            dictionaryKey: AnyCodable(.object([
                "Alpha": .string("DO NOT SEND THIS PHONETIC VALUE"),
                "Beta": .string("<phoneme>not recognition text</phoneme>")
            ])),
            ignoredKey: AnyCodable(.array([.string("beta")]))
        ])
        XCTAssertEqual(configuration.liveOptions.keywords, ["Explicit"])
        XCTAssertEqual(configuration.liveOptions.assemblyAIKeyterms, ["Explicit", "Alpha"])
        XCTAssertTrue(DesktopConfiguration.supportedKeys.contains(dictionaryKey))
        XCTAssertTrue(DesktopConfiguration.supportedKeys.contains(ignoredKey))
    }

    func testAbsentDictionary_PreservesExistingDesktopOptionShape() throws {
        let words = (0..<105).map { "Term\($0)" }
        let configuration = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string(words.joined(separator: "\n")))
        ])
        XCTAssertEqual(configuration.liveOptions.keywords, words)
        XCTAssertEqual(configuration.liveOptions.assemblyAIKeyterms, words)
    }

    func testApplyAndRestart_PreserveRawDictionaryIgnoredTermsAndUnknownValues() throws {
        let dictionary = AnyCodable(.object(["Alpha": .string("al-fa"), "Beta": .string("bee-ta")]))
        let ignored = AnyCodable(.array([.string("beta")]))
        let unknown = AnyCodable(.object(["future": .bool(true)]))
        let original = try DesktopConfiguration(values: [
            dictionaryKey: dictionary, ignoredKey: ignored, "futurePreference": unknown
        ])
        let applied = try original.applying(original.entries)
        let reloaded = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(applied)
        )
        XCTAssertEqual(reloaded.values[dictionaryKey], dictionary)
        XCTAssertEqual(reloaded.values[ignoredKey], ignored)
        XCTAssertEqual(reloaded.values["futurePreference"], unknown)
        XCTAssertEqual(reloaded.liveOptions.assemblyAIKeyterms, ["Alpha"])
        XCTAssertEqual(reloaded.liveOptions.keywords, [])
    }

    func testExplicitNativeClear_SuppressesSeedsInsteadOfRestoringClearedHints() throws {
        let original = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Explicit")),
            dictionaryKey: AnyCodable(.object(["Alpha": .string("al-fa")]))
        ])
        var entries = original.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "transcriptionKeywords" })
        entries[index] = ""
        let cleared = try original.applying(entries)
        XCTAssertEqual(cleared.liveOptions.assemblyAIKeyterms, [])
        XCTAssertEqual(cleared.values[ignoredKey], AnyCodable(.array([.string("alpha")])))
        let restarted = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(cleared)
        )
        XCTAssertEqual(restarted.liveOptions.assemblyAIKeyterms, [])
    }

    func testNativeReselection_RemovesOnlyTheSelectedSeedSuppression() throws {
        let original = try DesktopConfiguration(values: [
            dictionaryKey: AnyCodable(.object(["Alpha": .string("al-fa"), "Beta": .string("bee-ta")])),
            ignoredKey: AnyCodable(.array([.string("alpha"), .string("beta"), .string("unrelated")]))
        ])
        var entries = original.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "assemblyAIKeyterms" })
        entries[index] = "ALPHA"
        let selected = try original.applying(entries)
        XCTAssertEqual(selected.liveOptions.assemblyAIKeyterms, ["ALPHA"])
        XCTAssertEqual(selected.values[ignoredKey], AnyCodable(.array([.string("beta"), .string("unrelated")])))
    }

    func testMalformedLegacyPreferences_FailExplicitlyWithoutStringCoercion() {
        for invalid in [
            AnyCodable(.string("{}")), AnyCodable(.bool(true)), AnyCodable(.array([])),
            AnyCodable(.object(["Alpha": .int(1)]))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [dictionaryKey: invalid]))
        }
        for invalid in [
            AnyCodable(.string("alpha")), AnyCodable(.object([:])), AnyCodable(.array([.bool(true)]))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [ignoredKey: invalid]))
        }
    }

    func testRecoveredKeywordReselection_RemovesItsLegacySuppression() throws {
        let configuration = try DesktopConfiguration(values: [
            dictionaryKey: AnyCodable(.object(["Alpha": .string("al-fa")])),
            ignoredKey: AnyCodable(.array([.string("alpha"), .string("unrelated")])),
            "recoveredTranscriptionKeywords": AnyCodable(.array([.string("ALPHA")]))
        ])
        let recovered = try configuration.recoveringKeywords("ALPHA")
        XCTAssertEqual(recovered.liveOptions.assemblyAIKeyterms, ["ALPHA"])
        XCTAssertEqual(recovered.values[ignoredKey], AnyCodable(.array([.string("unrelated")])))
    }
}
