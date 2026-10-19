import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopVocabularyArchiveSourceTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Unused fixture digest for identified JSON records") {
        VocabularyArchiveFixtureHasher()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ data: Data, path: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func populate(_ root: URL) throws {
        for definition in DataMigrationVocabularyCatalog.collections {
            let data = try VocabularyMigrationFixtures.data(kind: definition.kind)
            try write(Data(" \n".utf8) + data + Data("\r\n".utf8), path: definition.desktopPath, root: root)
        }
    }

    private func collect(_ root: URL) throws -> DesktopVocabularyArchiveSource.Snapshot {
        try DesktopVocabularyArchiveSource.collect(appDirectory: root, digests: digests)
    }

    private func nativePreferences() -> Data {
        Data("""
        {"includeLexiconDirectives":true,"includeContextTags":false,"contextTags":["Synthetic"],
         "future":{"opaque":[null,true,42,{"retain":"unchanged"}]}}
        """.utf8)
    }

    func testStrictCollection_RetainsCanonicalKindOrderExactBytesRawValuesAndNativeComposite() throws {
        let root = try directory()
        try populate(root)
        let preferences = nativePreferences()
        try write(preferences, path: "vocabulary.json", root: root)
        let result = try collect(root)
        XCTAssertFalse(result.isCompleteCategory)
        XCTAssertEqual(result.collections.map(\.definition), DataMigrationVocabularyCatalog.collections)
        XCTAssertEqual(result.unmappedPreferences.data, preferences)
        for collection in result.collections {
            let source = try Data(contentsOf: root.appendingPathComponent(collection.definition.desktopPath))
            XCTAssertEqual(collection.source.data, source)
            let records = try XCTUnwrap(collection.records)
            XCTAssertEqual(records.map(\.value), try JSONDecoder().decode([AnyCodable].self, from: source))
            XCTAssertEqual(records.map(\.id),
                           [VocabularyMigrationFixtures.firstID, VocabularyMigrationFixtures.secondID])
            XCTAssertEqual(records, try DataMigrationVocabularyCatalog.records(
                data: source, kind: collection.definition.kind, digest: { _ in
                    XCTFail("Identified values must not be replaced with digests.")
                    return "unexpected"
                }
            ))
        }
        let projected = try result.projectCompatibleKinds()
        XCTAssertFalse(projected.isCompleteCategory)
        XCTAssertFalse(projected.scope.isComplete)
        XCTAssertEqual(projected.selectedKinds, Set(DataMigrationVocabularyCatalog.collections.map(\.kind)))
        XCTAssertEqual(projected.records.count, 6)
        XCTAssertFalse(projected.records.contains { $0.kind == "default" || $0.id == "vocabulary.json" })
    }

    func testPartialRealZIP_RoundTripsAllRawMembersAgedDismissedStateIDsDatesAndDeclaredScope() throws {
        let root = try directory()
        let staging = try directory()
        try populate(root)
        try write(nativePreferences(), path: "vocabulary.json", root: root)
        let source = try collect(root)
        let projection = try source.projectCompatibleKinds()
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.vocabulary], scopes: ["vocabulary": projection.scope]),
            records: [.vocabulary: projection.records]
        )
        let zip = try MigrationTestArchive.export(snapshot, digests: digests, stagingRoot: staging)
        let bytes = try Data(contentsOf: zip)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let restored = try MigrationTestArchive.read(zip, digests: digests, stagingRoot: staging)
        XCTAssertEqual(restored.records[.vocabulary], projection.records)
        XCTAssertEqual(restored.manifest.scopes["vocabulary"], projection.scope)
        XCTAssertFalse(try XCTUnwrap(restored.manifest.scopes["vocabulary"]).isComplete)
        XCTAssertTrue(restored.notices.isEmpty)
        for record in try XCTUnwrap(restored.records[.vocabulary]) {
            try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary)
        }
        let candidates = try projection.records.filter { $0.kind == "correction" }.map {
            try DataMigrationCoding.decode(AutoCorrectionCandidate.self, $0.value)
        }
        XCTAssertEqual(candidates.map(\.dismissed), [true, false])
        XCTAssertEqual(candidates.map(\.seenCount), [1, 1])
        XCTAssertEqual(candidates.first?.lastSeenAt, Date(timeIntervalSince1970: 946_771_200))
        try source.revalidate()
    }

    func testExistingEmptyVersusAnchoredAbsence_StayDistinctOutsideFlattenedVersionOneZIP() throws {
        let root = try directory()
        let staging = try directory()
        let absent = try collect(root)
        XCTAssertTrue(absent.collections.allSatisfy { $0.source.data == nil && $0.records == nil })
        for definition in DataMigrationVocabularyCatalog.collections {
            try write(Data("[]".utf8), path: definition.desktopPath, root: root)
        }
        let empty = try collect(root)
        XCTAssertTrue(empty.collections.allSatisfy { $0.source.data == Data("[]".utf8) && $0.records == [] })
        let absentProjection = DataMigrationSnapshot(
            manifest: .init(categories: [.vocabulary], scopes: ["vocabulary": .init(selectedIDs: [])]),
            records: [.vocabulary: []]
        )
        let partial = try empty.projectCompatibleKinds()
        let emptyProjection = DataMigrationSnapshot(
            manifest: .init(createdAt: absentProjection.manifest.createdAt, categories: [.vocabulary],
                            scopes: ["vocabulary": partial.scope]),
            records: [.vocabulary: partial.records]
        )
        let first = try MigrationTestArchive.export(absentProjection, digests: digests, stagingRoot: staging)
        let second = try MigrationTestArchive.export(emptyProjection, digests: digests, stagingRoot: staging)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertFalse(partial.scope.isComplete)
        XCTAssertThrowsError(try absent.projectCompatibleKinds())
    }

    func testMissingOwnedRoot_RefusesUnanchoredAbsenceAndCreatesNothing() throws {
        let root = try directory().appendingPathComponent("missing")
        XCTAssertThrowsError(try collect(root)) {
            guard case DesktopOwnedAppDataFileReadError.insufficientIdentity = $0 else {
                return XCTFail("Unexpected missing-root result: \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testInvalidOrDuplicateRecords_RefuseProjectionEvenWhenScopeWouldExcludeThem() throws {
        let root = try directory()
        let path = DataMigrationVocabularyCatalog.collections[2].desktopPath
        for data in [Data("{}".utf8), Data("[null]".utf8), Data("damaged".utf8),
                     Data(#"[{"id":"missing-required-fields"}]"#.utf8)] {
            try write(data, path: path, root: root)
            XCTAssertThrowsError(try collect(root).projectCompatibleKinds(scope: .init(selectedIDs: [])))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), data)
        }
        let values = try JSONDecoder().decode(
            [AnyCodable].self, from: VocabularyMigrationFixtures.data(kind: "correction")
        )
        try write(DataMigrationCoding.encoder.encode([values[0], values[0]]), path: path, root: root)
        XCTAssertThrowsError(try collect(root))
    }

    func testDamagedNativeComposite_IsRetainedOnDiskAndNeverInventedAsMacRecord() throws {
        let root = try directory()
        let raw = Data(#"{"future":true}"#.utf8)
        try write(raw, path: "vocabulary.json", root: root)
        XCTAssertThrowsError(try collect(root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("vocabulary.json")), raw)
    }

    func testSelectedIDsAndDates_UseCanonicalScopeWithoutCompleteCategoryAuthority() throws {
        let root = try directory()
        try populate(root)
        let source = try collect(root)
        let scope = DataMigrationScope(
            start: Date(timeIntervalSince1970: 1_704_067_199),
            end: Date(timeIntervalSince1970: 1_704_067_201),
            selectedIDs: [VocabularyMigrationFixtures.secondID]
        )
        let partial = try source.projectCompatibleKinds(scope: scope)
        XCTAssertEqual(partial.scope, scope)
        XCTAssertEqual(partial.records.map(\.kind), ["lexicon"])
        XCTAssertEqual(partial.records.map(\.id), [VocabularyMigrationFixtures.secondID])
        XCTAssertEqual(partial.selectedKinds, Set(DataMigrationVocabularyCatalog.collections.map(\.kind)))
        XCTAssertFalse(partial.isCompleteCategory)
    }

}

extension DesktopVocabularyArchiveSourceTests {
    func testProjection_RevalidatesAllSourcesEvenWhenEveryRecordIsExcluded() throws {
        for path in DataMigrationVocabularyCatalog.collections.map(\.desktopPath) + ["vocabulary.json"] {
            let root = try directory()
            try populate(root)
            try write(nativePreferences(), path: "vocabulary.json", root: root)
            let source = try collect(root)
            let file = root.appendingPathComponent(path)
            let original = try Data(contentsOf: file)
            try (original + Data(" ".utf8)).write(to: file, options: .atomic)
            XCTAssertThrowsError(try source.projectCompatibleKinds(scope: .init(selectedIDs: [])))
        }
    }

    func testSameSizeTimestampEditAndSourceAppearance_RefuseStalePartialProjection() throws {
        let root = try directory()
        let file = root.appendingPathComponent("pronunciation.json")
        let original = try VocabularyMigrationFixtures.data(kind: "pronunciation")
        try write(original, path: "pronunciation.json", root: root)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let source = try collect(root)
        let changed = try XCTUnwrap(String(data: original, encoding: .utf8))
            .replacingOccurrences(of: "Fixture", with: "Changed")
        XCTAssertEqual(Data(changed.utf8).count, original.count)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(changed.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        XCTAssertThrowsError(try source.projectCompatibleKinds())
        let current = try collect(root)
        try write(Data("[]".utf8), path: "AutoCorrections/candidates.json", root: root)
        XCTAssertThrowsError(try current.projectCompatibleKinds())
    }

    func testProjection_CancellationPropagatesDuringRecordFilteringAndBoundedRevalidation() throws {
        let root = try directory()
        try populate(root)
        let source = try collect(root)
        for stop in [2, 12] {
            var checks = 0
            XCTAssertThrowsError(try source.projectCompatibleKinds(checkCancellation: {
                checks += 1
                if checks == stop { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, stop)
        }
        try source.revalidate()
    }

    func testChangeDuringPartialProjection_RefusesInsteadOfPublishingStaleRecords() throws {
        let root = try directory()
        try populate(root)
        let source = try collect(root)
        var checks = 0
        XCTAssertThrowsError(try source.projectCompatibleKinds(checkCancellation: {
            checks += 1
            if checks == 2 {
                try Data("[]".utf8).write(to: root.appendingPathComponent("pronunciation.json"))
            }
        }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pronunciation.json")), Data("[]".utf8))
    }

    func testCollector_CancellationInterruptsRawChunksWithoutMutatingSource() throws {
        let root = try directory()
        let raw = Data("[".utf8) + Data(repeating: 0x20, count: 200_000) + Data("]".utf8)
        try write(raw, path: "pronunciation.json", root: root)
        var checks = 0
        XCTAssertThrowsError(try DesktopVocabularyArchiveSource.collect(
            appDirectory: root, digests: digests, checkCancellation: {
                checks += 1
                if checks == 7 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 7)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pronunciation.json")), raw)
    }

    func testSharedSourceBudget_RejectsOversizeBeforeReadingSparseJSON() throws {
        let root = try directory()
        let file = root.appendingPathComponent("pronunciation.json")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: DataMigrationArchivePolicy.maximumJSONBytes + 1)
        try handle.close()
        XCTAssertThrowsError(try collect(root)) {
            guard case DesktopOwnedAppDataFileReadError.exceedsByteBudget = $0 else {
                return XCTFail("Unexpected source budget error: \($0)")
            }
        }
    }

    #if !os(Windows)
    func testUnreadableSource_RefusesAuthorityRatherThanReturningMissing() throws {
        guard NSUserName() != "root" else { throw XCTSkip("Permission denial requires a non-root process.") }
        let root = try directory()
        try write(Data("[]".utf8), path: "pronunciation.json", root: root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("pronunciation.json").path
        )
        XCTAssertThrowsError(try collect(root))
    }

    func testLinkedSourceOrDirectory_RefusesOwnedAuthority() throws {
        let root = try directory()
        let external = try directory()
        let file = external.appendingPathComponent("source.json")
        try Data("[]".utf8).write(to: file)
        let link = root.appendingPathComponent("pronunciation.json")
        try FileManager.default.linkItem(at: file, to: link)
        XCTAssertThrowsError(try collect(root))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("PersonalLexicon"),
                                                  withDestinationURL: external)
        XCTAssertThrowsError(try collect(root))
    }
    #endif
}

private final class VocabularyArchiveFixtureHasher: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws {
        throw LocalModelDigestError.unavailable("Identified JSON fixture unexpectedly required hashing.")
    }
    func finish() throws -> String {
        throw LocalModelDigestError.unavailable("Identified JSON fixture unexpectedly required hashing.")
    }
}
