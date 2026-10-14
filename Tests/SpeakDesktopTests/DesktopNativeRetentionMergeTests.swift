import Foundation
import SpeakCore
import XCTest

final class DesktopNativeRetentionMergeTests: XCTestCase {
    private func records(
        _ value: AnyCodable?, platform: DesktopNativeConfigurationCapture.Platform = .windows
    ) throws -> [DataMigrationRecord] {
        let sources = value.map { ["postProcessing.customPrompt": $0] } ?? [:]
        return try DesktopNativeConfigurationArchiveCodec.project(.capture(
            sources, platform: platform, selectedFields: ["postProcessing.customPrompt"]
        )).records
    }

    func testEmptyInputAndAbsentIncoming_NeverClearRetainedValue() throws {
        let existing = try records(AnyCodable(.string("retained")))
        let empty = try DesktopNativeRetentionMergePolicy.plan(existing: existing, incoming: [])
        XCTAssertEqual(empty.proposed.records, existing)
        XCTAssertTrue(empty.additions.isEmpty)
        XCTAssertTrue(empty.conflicts.isEmpty)
        let missing = try DesktopNativeRetentionMergePolicy.plan(existing: existing, incoming: records(nil))
        XCTAssertEqual(missing.proposed.records, existing)
        XCTAssertTrue(missing.additions.isEmpty)
        XCTAssertEqual(missing.conflicts.count, 1)
        XCTAssertTrue(missing.hasConflicts)
    }

    func testAbsentNullAndEmptySource_AreDistinctExplicitConflicts() throws {
        let absent = try records(nil)
        for value in [AnyCodable(.null), AnyCodable(.string("")), AnyCodable(.string("  "))] {
            let incoming = try records(value)
            let plan = try DesktopNativeRetentionMergePolicy.plan(existing: absent, incoming: incoming)
            XCTAssertEqual(plan.conflicts.first?.existing, absent.first)
            XCTAssertEqual(plan.conflicts.first?.incoming, incoming.first)
            XCTAssertEqual(plan.proposed.records, absent)
            XCTAssertTrue(plan.hasConflicts)
        }
    }

    func testSameRawRecord_IsIdempotentAndAddsNoWriteAuthority() throws {
        let existing = try records(AnyCodable(.string("  raw\nprompt  ")))
        let plan = try DesktopNativeRetentionMergePolicy.plan(existing: existing, incoming: existing)
        XCTAssertTrue(plan.additions.isEmpty)
        XCTAssertEqual(plan.unchangedIDs, Set(existing.map(\.id)))
        XCTAssertFalse(plan.hasConflicts)
        XCTAssertEqual(plan.proposed.records, existing)
        XCTAssertFalse(plan.proposed.coverage.permitsReplacement)
    }

    func testForeignPlatform_IsSeparateIdentityAndInputOrderDoesNotMatter() throws {
        let windows = try records(AnyCodable(.string("Windows source")))
        let linux = try records(AnyCodable(.string("Linux source")), platform: .linux)
        let forward = try DesktopNativeRetentionMergePolicy.plan(existing: windows, incoming: linux)
        let reverse = try DesktopNativeRetentionMergePolicy.plan(existing: linux, incoming: windows)
        XCTAssertEqual(forward.proposed.records, reverse.proposed.records)
        XCTAssertEqual(forward.proposed.entries.map(\.platform), [.linux, .windows])
        XCTAssertEqual(forward.additions, linux)
        XCTAssertTrue(forward.conflicts.isEmpty)
    }

    func testConflictPlusAddition_ReportsConflictAndKeepsOriginalUnchanged() throws {
        let existing = try records(AnyCodable(.string("original")))
        let changed = try records(AnyCodable(.string("changed")))
        let foreign = try records(AnyCodable(.string("foreign")), platform: .linux)
        let plan = try DesktopNativeRetentionMergePolicy.plan(existing: existing, incoming: changed + foreign)
        XCTAssertTrue(plan.hasConflicts)
        XCTAssertEqual(plan.additions, foreign)
        XCTAssertEqual(plan.conflicts.first?.identity, existing.first?.id)
        XCTAssertEqual(plan.proposed.records.first { $0.id == existing.first?.id }, existing.first)
        XCTAssertEqual(existing, try records(AnyCodable(.string("original"))))
    }

    func testUnknownKindPathAndDuplicates_AbortRatherThanFiltering() throws {
        let original = try XCTUnwrap(records(AnyCodable(.string("source"))).first)
        var unknown = original
        unknown.id = "native/windows/vocabulary.json"
        XCTAssertThrowsError(try DesktopNativeRetentionMergePolicy.plan(existing: [], incoming: [unknown]))
        unknown = original
        unknown.kind = "default"
        XCTAssertThrowsError(try DesktopNativeRetentionMergePolicy.plan(existing: [unknown], incoming: []))
        XCTAssertThrowsError(try DesktopNativeRetentionMergePolicy.plan(existing: [], incoming: [original, original]))
    }

    func testCancellation_PropagatesBeforeAnyProposedSuccess() throws {
        let original = try records(AnyCodable(.string("source")))
        XCTAssertThrowsError(try DesktopNativeRetentionMergePolicy.plan(existing: original, incoming: []) {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testIncompatibleProvenance_IsExplicitlyRefusedBeforeAnyMergeCandidate() throws {
        let original = try XCTUnwrap(records(AnyCodable(.string("source"))).first)
        guard case .object(var envelope) = original.value.storage else {
            return XCTFail("Expected a closed source envelope.")
        }
        envelope["provenance"] = .string("legacyConfiguration")
        var changed = original
        changed.value = AnyCodable(.object(envelope))
        XCTAssertThrowsError(try DesktopNativeRetentionMergePolicy.plan(existing: [original], incoming: [changed]))
    }
}
