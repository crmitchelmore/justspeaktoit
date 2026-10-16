import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

@VocabularyActor
final class DesktopVocabularyTests: XCTestCase {
    func testNativeEventContractDurableCRUDOrderPreviewAndSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vocabulary = DesktopVocabulary(directory: directory)
        try await vocabulary.load()
        _ = try await vocabulary.perform(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Company", "AcmeCorp", "Acme\nAck me", "requireContextMatch", "work", "high", "Synthetic notes"
        ]))
        let id = try XCTUnwrap(vocabulary.lexicon.rules.first?.id)
        let result = vocabulary.apply("Acme")
        XCTAssertEqual(result.result.transformedText, "Acme")
        XCTAssertEqual(result.summary.suggestions.count, 1)
        let preview = try await vocabulary.perform(
            kind: 0, payload: DesktopVocabularyWire.encode(["preview", "Acme", "work"])
        )
        XCTAssertTrue(preview.hasPrefix("AcmeCorp\nApplied: 1"))
        _ = try await vocabulary.perform(
            kind: 0, payload: DesktopVocabularyWire.encode(["preferences", "true", "true", "work"])
        )
        XCTAssertEqual(vocabulary.apply("Acme").result.transformedText, "AcmeCorp")
        _ = try await vocabulary.perform(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", id.uuidString, "Company", "Acme Incorporated", "Acme", "automatic", "", "medium", ""
        ]))
        let reloaded = DesktopVocabulary(directory: directory)
        try await reloaded.load()
        XCTAssertEqual(reloaded.apply("Acme").result.transformedText, "Acme Incorporated")
        _ = try await reloaded.perform(kind: 0, payload: DesktopVocabularyWire.encode([
            "delete", id.uuidString, "", "", "", "", "", "", ""
        ]))
        XCTAssertTrue(reloaded.lexicon.rules.isEmpty)
        XCTAssertEqual(reloaded.apply("   ").result.transformedText, "")
    }

    func testPronunciationValidationRollbackAndDurableRendering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabulary = DesktopVocabulary(directory: root)
        try await vocabulary.load()
        let original = vocabulary.entries
        do {
            _ = try await vocabulary.perform(kind: 1, payload: DesktopVocabularyWire.encode([
                "save", "", "[invalid", "Test", "replacement", "Custom", "true", "false", ""
            ]))
            XCTFail("Invalid regex must fail")
        } catch {}
        XCTAssertEqual(vocabulary.entries, original)
        _ = try await vocabulary.perform(kind: 1, payload: DesktopVocabularyWire.encode([
            "save", "", "JSTI", "just speak", "just speak", "Custom", "false", "true", ""
        ]))
        let reload = DesktopVocabulary(directory: root)
        try await reload.load()
        XCTAssertEqual(reload.speechText("JSTI jsti"), "just speak jsti")
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: root.appendingPathComponent("pronunciation.json"))
        let failed = DesktopVocabulary(directory: root)
        do { try await failed.load(); XCTFail("Corruption must be reported") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pronunciation.json")), corrupt)
    }

    nonisolated func testEscapingPreservesUserTextAndRejectsMalformedEvents() throws {
        let values = ["%25", "tab\tvalue", "line\nvalue\r", "caf\u{00E9}", ""]
        XCTAssertEqual(try DesktopVocabularyWire.decode(DesktopVocabularyWire.encode(values)), values)
        XCTAssertThrowsError(try DesktopVocabularyWire.decode("%not-escaped"))
    }

    nonisolated func testProviderControlsArePreservedWhileAddingCanonicalKeywords() {
        let configured = LiveClientOptions(
            keywords: ["Configured"], assemblyAIKeyterms: ["AssemblyTerm"], modulate: .init(emotionSignal: true),
            postStopFinalizeBudget: 12, stopGracePeriod: 0.25
        )
        let options = configured.includingVocabularyKeywords(["configured", "SyntheticCanonical", ""])
        XCTAssertEqual(options.keywords, ["Configured", "SyntheticCanonical"])
        XCTAssertEqual(options.assemblyAIKeyterms, ["AssemblyTerm", "configured", "SyntheticCanonical"])
        XCTAssertEqual(options.modulate, configured.modulate)
        XCTAssertEqual(options.postStopFinalizeBudget, 12)
        XCTAssertEqual(options.stopGracePeriod, 0.25)
    }

    func testReloadReadsDurableStateAndStaleSavedIdentitiesAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DesktopVocabulary(directory: root), second = DesktopVocabulary(directory: root)
        try await first.load()
        try await second.load()
        _ = try await first.perform(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Fixture", "Canonical", "Fixture", "automatic", "", "high", ""
        ]))
        try await second.reload()
        XCTAssertEqual(second.apply("Fixture").result.transformedText, "Canonical")
        for kind in 0...1 {
            do {
                _ = try await second.perform(kind: kind, payload: DesktopVocabularyWire.encode([
                    "save", UUID().uuidString, "Stale", "stale", "replacement",
                    kind == 0 ? "automatic" : "Custom", kind == 0 ? "" : "false", kind == 0 ? "high" : "false", ""
                ]))
                XCTFail("An unknown saved ID must not create a new entry")
            } catch { XCTAssertEqual(error as? DesktopVocabularyError, .unknownEntry) }
        }
        let file = root.appendingPathComponent("pronunciation.json")
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: file)
        do { try await second.reload(); XCTFail("Reload must report corrupt data") } catch {}
        do {
            _ = try await second.perform(kind: 1, payload: DesktopVocabularyWire.encode(["defaults"]))
            XCTFail("A failed reload must block writes")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testConcurrentPronunciationEditsAreSerializedAndFailedSaveRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabulary = DesktopVocabulary(directory: root)
        try await vocabulary.load()
        let first = DesktopVocabularyWire.encode([
            "save", "", "FixtureOne", "one", "one", "Custom", "false", "false", ""
        ])
        let second = DesktopVocabularyWire.encode([
            "save", "", "FixtureTwo", "two", "two", "Custom", "false", "false", ""
        ])
        async let firstSave = vocabulary.perform(kind: 1, payload: first)
        async let secondSave = vocabulary.perform(kind: 1, payload: second)
        _ = try await (firstSave, secondSave)
        XCTAssertTrue(vocabulary.entries.contains { $0.word == "FixtureOne" })
        XCTAssertTrue(vocabulary.entries.contains { $0.word == "FixtureTwo" })
        let previous = vocabulary.entries
        let file = root.appendingPathComponent("pronunciation.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            _ = try await vocabulary.perform(kind: 1, payload: DesktopVocabularyWire.encode([
                "save", "", "FixtureThree", "three", "", "Custom", "false", "false", ""
            ]))
            XCTFail("Atomic persistence failure must be reported")
        } catch {}
        XCTAssertEqual(vocabulary.entries, previous)
    }

    func testPronunciationImportMergeReplaceExportAndInvalidInput() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let vocabulary = DesktopVocabulary(directory: root)
        try await vocabulary.load()
        let input = parent.appendingPathComponent("import.json"), output = parent.appendingPathComponent("export.json")
        let entry = PronunciationEntry(word: "JSTI", pronunciation: "just speak", replacement: "just speak")
        try JSONEncoder().encode([entry]).write(to: input)
        _ = try await vocabulary.perform(kind: 1, payload: DesktopVocabularyWire.encode(["importMerge", input.path]))
        XCTAssertTrue(vocabulary.entries.contains(entry))
        XCTAssertTrue(vocabulary.entries.count > 1)
        _ = try await vocabulary.perform(
            kind: 1, payload: DesktopVocabularyWire.encode(["importReplace", input.path])
        )
        XCTAssertEqual(vocabulary.entries, [entry])
        _ = try await vocabulary.perform(kind: 1, payload: DesktopVocabularyWire.encode(["export", output.path]))
        XCTAssertEqual(try JSONDecoder().decode([PronunciationEntry].self, from: Data(contentsOf: output)), [entry])
        try Data("invalid".utf8).write(to: input)
        do {
            _ = try await vocabulary.perform(
                kind: 1, payload: DesktopVocabularyWire.encode(["importReplace", input.path])
            )
            XCTFail("Corrupt input must not replace entries")
        } catch {}
        XCTAssertEqual(vocabulary.entries, [entry])
        do {
            _ = try await vocabulary.perform(
                kind: 1,
                payload: DesktopVocabularyWire.encode(["export", root.appendingPathComponent("settings.json").path])
            )
            XCTFail("Export must not overwrite app state")
        } catch {}
    }
}
