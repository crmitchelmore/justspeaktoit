import Foundation
import XCTest
import SpeakCore

final class DesktopKeywordConfigurationTests: XCTestCase {
    func testLegacyOnlyImportAndCompetingListsUseOneCanonicalPreference() throws {
        let legacy = try DesktopConfiguration(values: ["assemblyAIKeyterms": AnyCodable(.string("Legacy words"))])
        XCTAssertEqual(legacy.text("transcriptionKeywords"), "Legacy words")
        XCTAssertEqual(legacy.text("assemblyAIKeyterms"), "Legacy words")
        let competing = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Swift, Speak")),
            "assemblyAIKeyterms": AnyCodable(.string(" Speak , Grace, Swift "))
        ])
        XCTAssertEqual(competing.text("transcriptionKeywords"), "Swift, Speak, Grace")
        XCTAssertEqual(competing.liveOptions.keywords, competing.liveOptions.assemblyAIKeyterms)
    }

    func testSingleMirrorEditsAndDeliberateClearsOverrideAnUnchangedMirror() throws {
        for key in ["transcriptionKeywords", "assemblyAIKeyterms"] {
            for replacement in ["Replacement", ""] {
                var values: [String: AnyCodable] = [
                    "transcriptionKeywords": AnyCodable(.string("Original")),
                    "assemblyAIKeyterms": AnyCodable(.string("Original")),
                    "transcriptionKeywordsLastReconciled": AnyCodable(.string("Original"))
                ]
                values[key] = AnyCodable(.string(replacement))
                let reconciled = try DesktopConfiguration(values: values)
                XCTAssertEqual(reconciled.text("transcriptionKeywords"), replacement)
                XCTAssertEqual(reconciled.text("assemblyAIKeyterms"), replacement)
                XCTAssertTrue(reconciled.recoveredKeywords.isEmpty)
            }
        }
    }

    func testIndependentClearPreservesTheCompetingEditExactlyOnceAcrossRelaunchAndApply() throws {
        for cleared in ["transcriptionKeywords", "assemblyAIKeyterms"] {
            var values: [String: AnyCodable] = [
                "transcriptionKeywords": AnyCodable(.string("Canonical edit")),
                "assemblyAIKeyterms": AnyCodable(.string("Legacy edit")),
                "transcriptionKeywordsLastReconciled": AnyCodable(.string("Original"))
            ]
            let recovered = cleared == "transcriptionKeywords" ? "Legacy edit" : "Canonical edit"
            values[cleared] = AnyCodable(.string(""))
            let preferences = try DesktopConfiguration(values: values)
            XCTAssertEqual(preferences.text("transcriptionKeywords"), "")
            XCTAssertEqual(preferences.recoveredKeywords, [recovered])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(preferences)
            )
            let applied = try restored.applying(restored.entries)
            XCTAssertEqual(applied.text("assemblyAIKeyterms"), "")
            XCTAssertEqual(applied.recoveredKeywords, [recovered])
        }
    }

    func testInitialEmptyMirrorDoesNotDiscardLegacyWordsOrCreateAConflict() throws {
        let preferences = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string(" \n")),
            "assemblyAIKeyterms": AnyCodable(.string("Legacy edit"))
        ])
        XCTAssertEqual(preferences.text("transcriptionKeywords"), "Legacy edit")
        XCTAssertTrue(preferences.recoveredKeywords.isEmpty)
    }

    func testApplyThroughEitherNativeAliasUpdatesBothMirrors() throws {
        let original = try DesktopConfiguration(values: ["transcriptionKeywords": AnyCodable(.string("Original"))])
        for key in ["transcriptionKeywords", "assemblyAIKeyterms"] {
            var entries = original.entries
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = "Edited"
            let changed = try original.applying(entries)
            XCTAssertEqual(changed.text("transcriptionKeywords"), "Edited")
            XCTAssertEqual(changed.text("assemblyAIKeyterms"), "Edited")
            XCTAssertTrue(changed.recoveredKeywords.isEmpty)
        }
    }

    func testExplicitRecoveryRestoresOnlyTheSelectedListAndKeepsOpaqueValues() throws {
        let preferences = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string("Speak")),
            "recoveredTranscriptionKeywords": AnyCodable(.array([.string("First"), .string("Speak, Second")])),
            "future": AnyCodable(.object(["enabled": .bool(true)]))
        ])
        let recovered = try preferences.recoveringKeywords("Speak, Second")
        XCTAssertEqual(recovered.text("transcriptionKeywords"), "Speak, Second")
        XCTAssertEqual(recovered.text("assemblyAIKeyterms"), "Speak, Second")
        XCTAssertEqual(recovered.recoveredKeywords, ["First"])
        XCTAssertEqual(recovered.values["future"], preferences.values["future"])
        XCTAssertThrowsError(try preferences.recoveringKeywords("Missing edit"))
        var changedValues = preferences.values
        changedValues["recoveredTranscriptionKeywords"] = AnyCodable(.array([.string("New first edit")]))
        let changed = try DesktopConfiguration(values: changedValues)
        XCTAssertThrowsError(try changed.recoveringKeywords("First"), "A stale row must not restore its new occupant.")
    }

    func testReconciliationMetadataTypesAndBoundsAreStrictlyValidated() {
        for invalid in [AnyCodable(.bool(true)), AnyCodable(.string("bad\0text"))] {
            XCTAssertThrowsError(try DesktopConfiguration(values: ["transcriptionKeywordsLastReconciled": invalid]))
        }
        for invalid in [
            AnyCodable(.string("not an array")), AnyCodable(.array([.int(1)])),
            AnyCodable(.array([.string("bad\0text")])),
            AnyCodable(.array(Array(repeating: .string("entry"), count: 1_001)))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: ["recoveredTranscriptionKeywords": invalid]))
        }
        XCTAssertTrue(DesktopConfiguration.supportedKeys.contains("transcriptionKeywordsLastReconciled"))
        XCTAssertTrue(DesktopConfiguration.supportedKeys.contains("recoveredTranscriptionKeywords"))
    }

    func testMergingIndividuallyValidListsCannotExceedThePortableFieldLimit() {
        XCTAssertThrowsError(try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string(String(repeating: "a", count: 40_000))),
            "assemblyAIKeyterms": AnyCodable(.string(String(repeating: "b", count: 40_000)))
        ]))
    }

    func testNativeScalarValidationDoesNotMergeWithoutSavedMirrorHistory() throws {
        let original = try DesktopConfiguration(values: [
            "transcriptionKeywords": AnyCodable(.string(String(repeating: "a", count: 40_000)))
        ])
        var entries = original.entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "transcriptionKeywords" })
        entries[index] = String(repeating: "b", count: 40_000)
        XCTAssertNoThrow(try DesktopConfiguration.validateEntries(entries))
        let changed = try original.applying(entries)
        XCTAssertEqual(changed.text("assemblyAIKeyterms"), entries[index])
        XCTAssertThrowsError(try DesktopConfiguration().applying(entries))
        entries[index] += "\0"
        XCTAssertThrowsError(try DesktopConfiguration.validateEntries(entries))
        XCTAssertThrowsError(try DesktopConfiguration.validateEntries([]))
    }
}
