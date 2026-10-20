import Foundation
import SpeakCore
import XCTest

final class DataMigrationKindScopeTests: XCTestCase {
    func testLegacyManifest_RemainsReadableWithoutKindSelections() throws {
        let legacy = DataMigrationManifest(version: 1, categories: [.history], scopes: [:])
        XCTAssertNoThrow(try DataMigrationArchivePolicy.validateManifest(legacy))
        let restored = try DataMigrationCoding.decoder.decode(
            DataMigrationManifest.self, from: DataMigrationCoding.encoder.encode(legacy)
        )
        XCTAssertEqual(restored.version, 1)
        XCTAssertTrue((restored.scopes["history"] ?? .init()).contains(id: "any", date: nil))
    }

    func testKindScopes_RequireNewVersionSoOlderReadersCannotSilentlyIgnoreThem() throws {
        let scope = DataMigrationScope(selectedKinds: ["history"])
        let legacy = DataMigrationManifest(version: 1, categories: [.history], scopes: ["history": scope])
        XCTAssertThrowsError(try DataMigrationArchivePolicy.validateManifest(legacy))
        let current = DataMigrationManifest(categories: [.history], scopes: ["history": scope])
        XCTAssertEqual(current.version, 2)
        XCTAssertNoThrow(try DataMigrationArchivePolicy.validateManifest(current))
        let restored = try DataMigrationCoding.decoder.decode(
            DataMigrationManifest.self, from: DataMigrationCoding.encoder.encode(current)
        )
        XCTAssertEqual(restored.scopes["history"]?.selectedKinds, ["history"])
        XCTAssertThrowsError(try DataMigrationArchivePolicy.validateManifest(
            .init(version: 3, categories: [], scopes: [:])
        ))
    }

    func testKindSelection_IntersectsIdentityAndHalfOpenDatesAndMissingKindFailsClosed() {
        let start = Date(timeIntervalSince1970: 10)
        let end = Date(timeIntervalSince1970: 20)
        let scope = DataMigrationScope(start: start, end: end, selectedIDs: ["same"], selectedKinds: ["history"])
        XCTAssertTrue(scope.contains(id: "same", date: start, kind: "history"))
        XCTAssertFalse(scope.contains(id: "same", date: start, kind: "ttsUsage"))
        XCTAssertFalse(scope.contains(id: "other", date: start, kind: "history"))
        XCTAssertFalse(scope.contains(id: "same", date: end, kind: "history"))
        XCTAssertFalse(scope.contains(id: "same", date: nil, kind: "history"))
        XCTAssertFalse(scope.contains(id: "same", date: start))
        XCTAssertFalse(scope.isComplete)
        XCTAssertFalse(DataMigrationScope(selectedKinds: []).contains(kind: "history"))
    }

    func testHistoryOnlyReplace_PreservesSpeechUsageEvenWithTheSameIdentifier() throws {
        let history = record("same", kind: "history", value: "Old recording History")
        let speech = record("same", kind: "ttsUsage", value: "Retained speech usage")
        let incoming = snapshot(
            [record("same", kind: "history", value: "Imported recording History")],
            category: .history, scope: .init(selectedKinds: ["history"])
        )
        let output = try plan(snapshot([history, speech], category: .history), incoming, category: .history)
        XCTAssertEqual(output.records[.history]?.filter { $0.kind == "ttsUsage" }, [speech])
        XCTAssertEqual(output.records[.history]?.count, 2)
        XCTAssertTrue(output.records[.history]?.contains {
            $0.kind == "history" && $0.value == AnyCodable(.string("Imported recording History"))
        } == true)
    }

    func testPreferenceOnlyReplace_PreservesVocabularyCollections() throws {
        let lexicon = record("rule", kind: "lexicon", value: "Retained raw lexicon")
        let current = snapshot(
            [record("transcriptionKeywords", kind: "default", value: "Old"), lexicon], category: .vocabulary
        )
        let incoming = snapshot(
            [record("transcriptionKeywords", kind: "default", value: "New")],
            category: .vocabulary, scope: .init(selectedKinds: ["default", "jsonDefault"])
        )
        let output = try plan(current, incoming, category: .vocabulary)
        XCTAssertTrue(output.records[.vocabulary]?.contains(lexicon) == true)
        XCTAssertEqual(output.records[.vocabulary]?.count, 2)
    }

    func testValidation_RejectsOutOfKindRecordsAndPreservesCategoryDamageNotice() throws {
        let incoming = snapshot(
            [record("selected", kind: "history", value: "Valid"),
             record("unselected", kind: "ttsUsage", value: "Outside selection")],
            category: .history, scope: .init(selectedKinds: ["history"])
        )
        let checked = try DataMigrationRecordValidation.validate(
            incoming, checkCancellation: {}, recordValidator: { _, _ in }
        )
        XCTAssertEqual(checked.records[.history]?.map(\.id), ["selected"])
        XCTAssertEqual(checked.notices.count, 1)
        XCTAssertTrue(checked.notices[0].hasPrefix(DataMigrationCategory.history.title + ","))
    }

    func testPreferenceKeyCoverage_PreservesUnmappedDefaultsOfTheSameKind() throws {
        let unsupported = record("selectedHotKey", kind: "jsonDefault", value: "Retained platform shortcut")
        let current = snapshot(
            [record("showHUD", kind: "default", value: "Old"), unsupported], category: .settings
        )
        let incoming = snapshot(
            [record("showHUD", kind: "default", value: "New")], category: .settings,
            scope: .init(selectedIDs: ["showHUD"], selectedKinds: ["default", "jsonDefault"])
        )
        let output = try plan(current, incoming, category: .settings)
        XCTAssertTrue(output.records[.settings]?.contains(unsupported) == true)
        XCTAssertEqual(output.records[.settings]?.count, 2)
    }

    func testInvalidAndUnboundedKindSelections_AreRejected() {
        for kinds in [Set([""]), Set(["bad\0kind"]), Set([String(repeating: "a", count: 129)]),
                      Set((0...100).map { "kind-\($0)" })] {
            let manifest = DataMigrationManifest(
                categories: [.history], scopes: ["history": .init(selectedKinds: kinds)]
            )
            XCTAssertThrowsError(try DataMigrationArchivePolicy.validateManifest(manifest))
        }
    }

    func testEmptyHistorySource_ReplacesOnlyItsDeclaredKind() throws {
        let speech = record("speech", kind: "ttsUsage", value: "Retained usage")
        let current = snapshot([record("history", kind: "history", value: "Old"), speech], category: .history)
        let incoming = snapshot([], category: .history, scope: .init(selectedKinds: ["history"]))
        XCTAssertEqual(try plan(current, incoming, category: .history).records[.history], [speech])
        let emptyCoverage = snapshot([], category: .history, scope: .init(selectedKinds: []))
        XCTAssertEqual(try plan(current, emptyCoverage, category: .history).records, current.records)
    }

    func testKindScopedVocabularyDates_KeepUndatedAndOutsideEntries() throws {
        let start = Date(timeIntervalSince1970: 10)
        let end = Date(timeIntervalSince1970: 20)
        var selected = record("selected", kind: "lexicon", value: "Inside")
        selected.date = start
        var outside = record("outside", kind: "lexicon", value: "Outside")
        outside.date = end
        let undated = record("undated", kind: "lexicon", value: "No date")
        let current = snapshot([selected, outside, undated], category: .vocabulary)
        let incoming = snapshot(
            [], category: .vocabulary, scope: .init(start: start, end: end, selectedKinds: ["lexicon"])
        )
        XCTAssertEqual(try plan(current, incoming, category: .vocabulary).records[.vocabulary], [outside, undated])
    }

    func testCoveredKeysAndDates_RejectOutOfScopeRecordsBeforeReplace() throws {
        let current = snapshot([record("showHUD", kind: "default", value: "Keep")], category: .settings)
        for scope in [
            DataMigrationScope(selectedIDs: ["appearance"], selectedKinds: ["default"]),
            DataMigrationScope(start: Date(timeIntervalSince1970: 10), selectedKinds: ["default"])
        ] {
            let incoming = snapshot(
                [record("showHUD", kind: "default", value: "Invalid")], category: .settings, scope: scope
            )
            let checked = try DataMigrationRecordValidation.validate(
                incoming, checkCancellation: {}, recordValidator: { _, _ in }
            )
            XCTAssertEqual(checked.records[.settings], [])
            XCTAssertEqual(checked.notices.count, 1)
            XCTAssertEqual(try plan(current, checked, category: .settings).records, current.records)
        }
    }

    private func record(_ id: String, kind: String, value: String) -> DataMigrationRecord {
        .init(id: id, kind: kind, value: AnyCodable(.string(value)))
    }

    private func snapshot(
        _ records: [DataMigrationRecord], category: DataMigrationCategory, scope: DataMigrationScope = .init()
    ) -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [category], scopes: [category.rawValue: scope]), records: [category: records])
    }

    private func plan(
        _ current: DataMigrationSnapshot, _ incoming: DataMigrationSnapshot, category: DataMigrationCategory
    ) throws -> DataMigrationSnapshot {
        try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: [category: .replace], useImported: [],
            digest: { _ in String(repeating: "a", count: 64) }
        )
    }
}
