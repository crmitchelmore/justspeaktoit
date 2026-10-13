import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest

final class DataMigrationPlannerTests: XCTestCase {
    private func record(
        _ value: String = "Original", id: String = "session", kind: String = "history",
        date: Date? = nil, revision: String? = nil
    ) -> DataMigrationRecord {
        .init(id: id, kind: kind, value: AnyCodable(.string(value)), date: date, revision: revision)
    }

    private func snapshot(
        _ category: DataMigrationCategory, _ records: [DataMigrationRecord],
        scope: DataMigrationScope = .init()
    ) -> DataMigrationSnapshot {
        .init(
            manifest: .init(categories: [category], scopes: [category.rawValue: scope]),
            records: [category: records]
        )
    }

    private func plan(
        current: DataMigrationSnapshot, incoming: DataMigrationSnapshot,
        modes: [DataMigrationCategory: DataMigrationMode], useImported: Set<String> = []
    ) throws -> DataMigrationSnapshot {
        try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: modes, useImported: useImported,
            digest: MigrationPlannerFixtures.digest
        )
    }

    func testConfigurationConflict_RequiresExplicitCategoryAndIdentityChoice() throws {
        let old = record("light", id: "appearance", kind: "default")
        let new = record("dark", id: "appearance", kind: "default")
        let current = snapshot(.settings, [old])
        let incoming = snapshot(.settings, [new])
        let conflicts = DataMigrationPlanner.conflicts(current: current, incoming: incoming, modes: [.settings: .merge])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.id, "settings:default:appearance")
        XCTAssertEqual(conflicts.first?.title, "appearance")
        XCTAssertEqual(conflicts.first?.existing, old)
        XCTAssertEqual(conflicts.first?.imported, new)
        XCTAssertEqual(
            try plan(current: current, incoming: incoming, modes: [.settings: .merge]).records[.settings], [old]
        )
        XCTAssertEqual(
            try plan(current: current, incoming: incoming, modes: [.settings: .merge],
                     useImported: ["settings:default:appearance"]).records[.settings], [new]
        )
        XCTAssertTrue(DataMigrationPlanner.conflicts(current: current, incoming: incoming,
                                                    modes: [.settings: .replace]).isEmpty)
    }

    func testHistoryMerge_PreservesVersionsWithMacCompatibleIdempotentIdentifiers() throws {
        let original = record()
        let changed = record("Changed", revision: "changed")
        let current = snapshot(.history, [original])
        let incoming = snapshot(.history, [changed])
        let merged = try plan(current: current, incoming: incoming, modes: [.history: .merge])
        XCTAssertEqual(merged.records[.history]?.map(\.id), ["session", MigrationPlannerFixtures.changedID])
        XCTAssertEqual(merged.records[.history]?.map(\.value), [original.value, changed.value])
        XCTAssertEqual(
            try plan(current: merged, incoming: incoming, modes: [.history: .merge]).records, merged.records
        )
        XCTAssertTrue(DataMigrationPlanner.conflicts(current: current, incoming: incoming,
                                                    modes: [.history: .merge]).isEmpty)
    }

    func testReplacement_UsesInclusiveStartAndExclusiveEnd() throws {
        let before = record(id: "before", date: Date(timeIntervalSince1970: 49))
        let start = record(id: "start", date: Date(timeIntervalSince1970: 50))
        let inside = record(id: "inside", date: Date(timeIntervalSince1970: 100))
        let end = record(id: "end", date: Date(timeIntervalSince1970: 150))
        let undated = record(id: "undated")
        let scope = DataMigrationScope(start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150))
        let result = try plan(
            current: snapshot(.history, [before, start, inside, end, undated]),
            incoming: snapshot(.history, [], scope: scope), modes: [.history: .replace]
        )
        XCTAssertEqual(result.records[.history], [before, end, undated])
    }

    func testSelectedReplacement_EmptySelectionPreservesAllAndNonemptySelectionIsExact() throws {
        let first = record()
        let other = record(id: "other")
        let current = snapshot(.recordings, [first, other])
        XCTAssertEqual(
            try plan(current: current, incoming: snapshot(.recordings, [], scope: .init(selectedIDs: [])),
                     modes: [.recordings: .replace]).records, current.records
        )
        XCTAssertEqual(
            try plan(current: current, incoming: snapshot(.recordings, [], scope: .init(selectedIDs: ["session"])),
                     modes: [.recordings: .replace]).records[.recordings], [other]
        )
    }

    func testInvalidItems_ColonAndItemNoticesPreventDestructiveReplacement() throws {
        let current = snapshot(.history, [record()])
        for notice in ["\(DataMigrationCategory.history.title): unreadable.",
                       "\(DataMigrationCategory.history.title), item 1: invalid."] {
            var incoming = snapshot(.history, [])
            incoming.notices = [notice]
            let result = try plan(current: current, incoming: incoming, modes: [.history: .replace])
            XCTAssertEqual(result.records, current.records)
            XCTAssertEqual(result.notices.first, notice)
            XCTAssertTrue(result.notices.contains { $0.contains("preserved existing items") })
        }
    }

    func testMissingCategory_IsNotAnEmptyReplacement() throws {
        let current = snapshot(.history, [record()])
        var incoming = snapshot(.history, [])
        incoming.records.removeValue(forKey: .history)
        XCTAssertEqual(
            try plan(current: current, incoming: incoming, modes: [.history: .replace]).records, current.records
        )
    }

    func testSkippedAndUnselectedCategories_DoNotModifyRecords() throws {
        let current = snapshot(.settings, [record("light", kind: "default")])
        let incoming = snapshot(.settings, [record("dark", kind: "default")])
        let selections: [[DataMigrationCategory: DataMigrationMode]] = [[:], [.settings: .skip]]
        for modes in selections {
            XCTAssertEqual(try plan(current: current, incoming: incoming, modes: modes).records, current.records)
            XCTAssertTrue(DataMigrationPlanner.conflicts(current: current, incoming: incoming, modes: modes).isEmpty)
        }
    }

    func testHistoryEquivalence_IgnoresOnlyIdentityAndUpdatedAt() throws {
        let original = DataMigrationRecord(
            id: "session", kind: "history",
            value: try AnyCodable(["id": "old", "updatedAt": "yesterday", "rawTranscription": "same"])
        )
        let imported = DataMigrationRecord(
            id: "session", kind: "history",
            value: try AnyCodable(["id": "new", "updatedAt": "today", "rawTranscription": "same"])
        )
        XCTAssertEqual(
            try plan(current: snapshot(.history, [original]), incoming: snapshot(.history, [imported]),
                     modes: [.history: .merge]).records[.history], [original]
        )
    }

    func testAudioEquivalence_UsesDigestRatherThanFileOrMetadata() throws {
        var original = record(kind: "audio")
        original.digest = "same digest"
        var imported = record("different metadata", kind: "audio")
        imported.digest = original.digest
        imported.file = "recordings/another.wav"
        XCTAssertEqual(
            try plan(current: snapshot(.recordings, [original]), incoming: snapshot(.recordings, [imported]),
                     modes: [.recordings: .merge]).records[.recordings], [original]
        )
    }

    func testHistoryMerge_TextEnrichesAudioOnlyButAudioOnlyCannotEraseText() throws {
        let audioOnly = DataMigrationRecord(
            id: "session", kind: "history", value: try AnyCodable(["audioFileURL": "recordings/test.wav"])
        )
        let text = DataMigrationRecord(
            id: "session", kind: "history", value: try AnyCodable(["rawTranscription": "transcript"])
        )
        XCTAssertEqual(
            try plan(current: snapshot(.history, [audioOnly]), incoming: snapshot(.history, [text]),
                     modes: [.history: .merge]).records[.history], [text]
        )
        XCTAssertEqual(
            try plan(current: snapshot(.history, [text]), incoming: snapshot(.history, [audioOnly]),
                     modes: [.history: .merge]).records[.history], [text]
        )
    }

    func testMissingRevision_UsesCanonicalJSONDigestAndMacCompatibleVariant() throws {
        let result = try plan(
            current: snapshot(.history, [record()]), incoming: snapshot(.history, [record("Changed")]),
            modes: [.history: .merge]
        )
        XCTAssertEqual(result.records[.history]?.last?.id, MigrationPlannerFixtures.fallbackID)
    }

    func testVariantCollision_UsesValueDigestAndRemainsIdempotent() throws {
        let incoming = snapshot(.history, [record("Changed", revision: "shared"),
                                          record("Changed again", revision: "shared")])
        let result = try plan(current: snapshot(.history, [record()]), incoming: incoming, modes: [.history: .merge])
        XCTAssertEqual(result.records[.history]?.map(\.id),
                       ["session", MigrationPlannerFixtures.sharedID, MigrationPlannerFixtures.collisionID])
        XCTAssertEqual(
            try plan(current: result, incoming: incoming, modes: [.history: .merge]).records, result.records
        )
    }

    func testAudioAndHistoryVariants_ReconnectWithoutAttachingTextToOlderAudio() throws {
        var oldAudio = record("older audio", kind: "audio")
        oldAudio.digest = "old"
        var newAudio = record("new audio", kind: "audio", revision: "linked")
        newAudio.digest = "new"
        let importedText = record("Changed", revision: "linked")
        var incoming = snapshot(.recordings, [newAudio])
        incoming.manifest.categories.append(.history)
        incoming.records[.history] = [importedText]
        let modes: [DataMigrationCategory: DataMigrationMode] = [.history: .merge, .recordings: .merge]
        let result = try plan(current: snapshot(.recordings, [oldAudio]), incoming: incoming, modes: modes)
        XCTAssertEqual(result.records[.recordings]?.map(\.id), ["session", MigrationPlannerFixtures.linkedID])
        XCTAssertEqual(result.records[.history]?.map(\.id), [MigrationPlannerFixtures.linkedID])
        XCTAssertEqual(try plan(current: result, incoming: incoming, modes: modes).records, result.records)
    }

    func testPlanning_PreservesManifestDirectoryAndMergesMaterializedFiles() throws {
        var current = snapshot(.settings, [])
        let root = FileManager.default.temporaryDirectory
        current.directory = root.appendingPathComponent("current")
        current.files = ["old": root.appendingPathComponent("old"), "same": root.appendingPathComponent("before")]
        var incoming = snapshot(.settings, [])
        incoming.files = ["new": root.appendingPathComponent("new"), "same": root.appendingPathComponent("after")]
        let result = try plan(current: current, incoming: incoming, modes: [.settings: .merge])
        XCTAssertEqual(result.manifest.createdAt, current.manifest.createdAt)
        XCTAssertEqual(result.directory, current.directory)
        XCTAssertEqual(result.files["old"], current.files["old"])
        XCTAssertEqual(result.files["new"], incoming.files["new"])
        XCTAssertEqual(result.files["same"], incoming.files["same"])
    }

    func testDigestFailure_IsReportedWithoutMutatingInput() throws {
        let current = snapshot(.history, [record()])
        let incoming = snapshot(.history, [record("Changed", revision: "changed")])
        XCTAssertThrowsError(try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: [.history: .merge], useImported: [],
            digest: { _ in throw LocalModelDigestError.unavailable("synthetic fixture") }
        ))
        XCTAssertEqual(current.records[.history], [record()])
    }

    func testInvalidDigestShape_IsRejectedBeforeIdentifierConstruction() {
        for invalid in ["", "00", String(repeating: "F", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try DataMigrationPlanner.plan(
                current: snapshot(.history, [record()]),
                incoming: snapshot(.history, [record("Changed", revision: "changed")]),
                modes: [.history: .merge], useImported: [], digest: { _ in invalid }
            ))
        }
    }

    func testUnencodableValue_ThrowsInsteadOfHashingEmptyData() {
        let imported = DataMigrationRecord(id: "session", kind: "history", value: AnyCodable(.double(.nan)))
        XCTAssertThrowsError(try plan(
            current: snapshot(.history, [record()]), incoming: snapshot(.history, [imported]), modes: [.history: .merge]
        ))
    }

    func testDesktopAdapter_UsesInjectedDigestForCanonicalFallbackRevision() throws {
        let digests = LocalModelDigestProvider(name: "Independent golden vectors") { MigrationFixtureHasher() }
        let result = try DesktopMigrationPlanner.plan(
            current: snapshot(.history, [record()]), incoming: snapshot(.history, [record("Changed")]),
            modes: [.history: .merge], useImported: [], digests: digests
        )
        XCTAssertEqual(result.records[.history]?.last?.id, MigrationPlannerFixtures.fallbackID)
    }

    func testCancelledPlanning_ThrowsBeforeProducingAnApplicableSnapshot() async throws {
        let current = snapshot(.history, [record()])
        let incoming = snapshot(.history, [record("Changed", revision: "changed")])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DataMigrationPlanner.plan(
                current: current, incoming: incoming, modes: [.history: .merge], useImported: [],
                digest: MigrationPlannerFixtures.digest
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled planning must not produce a snapshot for application.")
        } catch is CancellationError {
            XCTAssertEqual(current.records[.history], [record()])
        }
    }
}

private final class MigrationFixtureHasher: LocalModelSHA256Hasher {
    private var data = Data()

    func update(_ bytes: UnsafeRawBufferPointer) throws {
        data.append(contentsOf: bytes)
    }

    func finish() throws -> String {
        try MigrationPlannerFixtures.digest(data)
    }
}
