import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class VocabularySensitiveProjectionTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Identified synthetic vocabulary") { SensitiveFixtureHasher() }
    private let source = DesktopNativeSourceDocument.Source.desktopVocabularyPreferences
    private let platform = DesktopNativeSourceDocument.Platform.windows

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
            try write(VocabularyMigrationFixtures.data(kind: definition.kind), path: definition.desktopPath, root: root)
        }
    }

    private func collect(_ root: URL) throws -> DesktopVocabularyArchiveSource.Snapshot {
        try DesktopVocabularyArchiveSource.collectSensitiveEvidence(
            appDirectory: root, digests: digests, allowSensitiveContent: true
        )
    }

    private func validNative() -> Data {
        Data("""
        {"includeLexiconDirectives":true,"includeContextTags":false,"contextTags":["Synthetic"],
        "unknown":{"members":[null,true,{"retain":"original bytes"}]}}
        """.utf8)
    }

    func testBothOptIns_RefuseBeforeCollectionOrProjectionCancellationWork() throws {
        let root = try directory()
        var checks = 0
        XCTAssertThrowsError(try DesktopVocabularyArchiveSource.collectSensitiveEvidence(
            appDirectory: root.appendingPathComponent("missing"), digests: digests, checkCancellation: { checks += 1 }
        )) { XCTAssertTrue($0 is DataMigrationError) }
        XCTAssertEqual(checks, 0)
        let snapshot = try collect(root)
        XCTAssertThrowsError(try snapshot.projectWithSensitiveNativeEvidence(
            platform: platform, checkCancellation: { checks += 1 }
        )) { XCTAssertTrue($0 is DataMigrationError) }
        XCTAssertEqual(checks, 0)
    }

    func testOpaqueComposite_PreservesMissingEmptyMalformedUnknownAndOriginalBytesWithSeparateDomainState() throws {
        let variants: [Data?] = [
            nil, Data(), Data("{".utf8), Data(#"{"unknown":[null,true]}"#.utf8),
            Data([0xFF, 0xFE, 0x7B, 0, 0x7D, 0]), validNative()
        ]
        for raw in variants {
            let root = try directory()
            if let raw { try write(raw, path: source.path, root: root) }
            let snapshot = try collect(root)
            let projection = try snapshot.projectWithSensitiveNativeEvidence(
                platform: platform, allowSensitiveContent: true
            )
            let expected: DesktopVocabularyArchiveSource.NativeDomainValidity =
                raw == nil ? .absent : (raw == validNative() ? .valid : .invalid)
            XCTAssertEqual(snapshot.nativeDomainValidity, expected)
            XCTAssertEqual(projection.nativeDomainValidity, expected)
            XCTAssertEqual(projection.nativeSourceIsPresent, raw != nil)
            XCTAssertEqual(try XCTUnwrap(projection.nativeEvidence).rawBytes, raw)
            XCTAssertEqual(projection.records.count, 1)
            let restored = try DesktopNativeSourceDocumentCodec.decode(
                XCTUnwrap(projection.records.first), allowSensitiveContent: true
            )
            XCTAssertEqual(restored.rawBytes, raw)
            XCTAssertFalse(projection.hasApplyOrBackupAuthority)
            XCTAssertFalse(projection.isCompleteCategory)
            XCTAssertFalse(projection.scope.isComplete)
            XCTAssertEqual(projection.scope.selectedIDs, [restored.identity])
            if expected == .invalid {
                XCTAssertThrowsError(try snapshot.projectCompatibleKinds())
                XCTAssertThrowsError(try DesktopVocabularyArchiveSource.collect(appDirectory: root, digests: digests))
            }
        }
    }

    func testLegacyAndAdditiveCanonicalProjection_AreEquivalentForAcceptedNativeAndAllThreeRawKinds() throws {
        let root = try directory()
        try populate(root)
        try write(validNative(), path: source.path, root: root)
        let legacy = try DesktopVocabularyArchiveSource.collect(appDirectory: root, digests: digests)
        let additive = try collect(root)
        for scope in [DataMigrationScope(), .init(selectedIDs: []),
                      .init(selectedIDs: [VocabularyMigrationFixtures.secondID])] {
            let old = try legacy.projectCompatibleKinds(scope: scope)
            let retained = try additive.projectCompatibleKinds(scope: scope)
            XCTAssertEqual(old.records, retained.records)
            XCTAssertEqual(old.scope, retained.scope)
            XCTAssertEqual(old.selectedKinds, retained.selectedKinds)
            let mixed = try additive.projectWithSensitiveNativeEvidence(
                platform: platform, allowSensitiveContent: true, scope: scope
            )
            XCTAssertEqual(mixed.records.filter { $0.kind != DesktopNativeSourceDocumentCodec.recordKind }, old.records)
            XCTAssertEqual(mixed.collectionPresence, Dictionary(uniqueKeysWithValues:
                DataMigrationVocabularyCatalog.collections.map { ($0.kind, true) }))
        }
        let mixed = try additive.projectWithSensitiveNativeEvidence(platform: platform, allowSensitiveContent: true)
        XCTAssertEqual(mixed.records.count, 7)
        XCTAssertEqual(mixed.selectedKinds, Set(DataMigrationVocabularyCatalog.collections.map(\.kind))
            .union([DesktopNativeSourceDocumentCodec.recordKind]))
        XCTAssertEqual(additive.collections.map(\.source.data), legacy.collections.map(\.source.data))
    }

    func testCanonicalPresence_ReportsAbsentVersusEmptyWithoutInventingEntriesOrCompleteScope() throws {
        let root = try directory()
        let absent = try collect(root).projectWithSensitiveNativeEvidence(
            platform: platform, allowSensitiveContent: true
        )
        for definition in DataMigrationVocabularyCatalog.collections {
            try write(Data("[]".utf8), path: definition.desktopPath, root: root)
        }
        let empty = try collect(root).projectWithSensitiveNativeEvidence(
            platform: platform, allowSensitiveContent: true
        )
        XCTAssertEqual(absent.records, empty.records)
        XCTAssertTrue(absent.collectionPresence.values.allSatisfy { !$0 })
        XCTAssertTrue(empty.collectionPresence.values.allSatisfy { $0 })
        XCTAssertFalse(empty.isCompleteCategory)
    }

    func testDamagedCanonicalArray_StillFailsEvenWithExplicitMalformedNativeEvidenceOptIn() throws {
        for definition in DataMigrationVocabularyCatalog.collections {
            for invalid in [Data(), Data("{}".utf8), Data("[null]".utf8), Data("damaged".utf8)] {
                let root = try directory()
                try write(Data("{".utf8), path: source.path, root: root)
                try write(invalid, path: definition.desktopPath, root: root)
                XCTAssertThrowsError(try collect(root))
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(definition.desktopPath)), invalid)
            }
        }
    }

    func testEveryReceipt_IsRevalidatedAfterProjectionEvenWhenAllIDsAreExcluded() throws {
        for path in DataMigrationVocabularyCatalog.collections.map(\.desktopPath) + [source.path] {
            let root = try directory()
            try populate(root)
            try write(validNative(), path: source.path, root: root)
            let snapshot = try collect(root)
            var checks = 0
            XCTAssertThrowsError(try snapshot.projectWithSensitiveNativeEvidence(
                platform: platform, allowSensitiveContent: true, scope: .init(selectedIDs: []),
                checkCancellation: {
                    checks += 1
                    if checks == 2 {
                        let file = root.appendingPathComponent(path)
                        try (Data(contentsOf: file) + Data(" ".utf8)).write(to: file, options: .atomic)
                    }
                }
            )) {
                guard case DesktopOwnedAppDataFileReadError.changedSource = $0 else {
                    return XCTFail("Expected changed-source refusal, not \(type(of: $0)).")
                }
            }
            XCTAssertGreaterThan(checks, 2)
        }
    }

    func testAnchoredAbsence_SourceAppearanceDuringProjectionIsNotAnEmptyClear() throws {
        let root = try directory()
        let snapshot = try collect(root)
        var checks = 0
        XCTAssertThrowsError(try snapshot.projectWithSensitiveNativeEvidence(
            platform: platform, allowSensitiveContent: true, checkCancellation: {
                checks += 1
                if checks == 2 { try self.write(Data("{".utf8), path: self.source.path, root: root) }
            }
        ))
        XCTAssertEqual(snapshot.nativeDomainValidity, .absent)
    }

    func testCancellation_PropagatesThroughCollectionAndLongOpaqueProjectionWithoutDomainFallback() throws {
        let root = try directory()
        try write(Data(repeating: 0xAA, count: 100_000), path: source.path, root: root)
        XCTAssertThrowsError(try DesktopVocabularyArchiveSource.collectSensitiveEvidence(
            appDirectory: root, digests: digests, allowSensitiveContent: true,
            checkCancellation: { throw CancellationError() }
        )) { XCTAssertTrue($0 is CancellationError) }
        let snapshot = try collect(root)
        for stop in [1, 8, 30] {
            var checks = 0
            XCTAssertThrowsError(try snapshot.projectWithSensitiveNativeEvidence(
                platform: platform, allowSensitiveContent: true, checkCancellation: {
                    checks += 1
                    if checks == stop { throw CancellationError() }
                }
            )) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, stop)
        }
    }

    func testMixedKinds_MacRejectsNativePayloadAndDateScopeDoesNotInventNativeTimestamp() throws {
        let root = try directory()
        try populate(root)
        try write(validNative(), path: source.path, root: root)
        let snapshot = try collect(root)
        let mixed = try snapshot.projectWithSensitiveNativeEvidence(platform: platform, allowSensitiveContent: true)
        XCTAssertThrowsError(try mixed.records.forEach {
            try DataMigrationVocabularyCatalog.validate($0, category: .vocabulary)
        })
        XCTAssertFalse(try XCTUnwrap(mixed.nativeEvidence).hasApplyOrBackupAuthority)
        let filtered = try snapshot.projectWithSensitiveNativeEvidence(
            platform: platform, allowSensitiveContent: true, scope: .init(start: Date(timeIntervalSince1970: 0))
        )
        XCTAssertNil(filtered.nativeEvidence)
        XCTAssertFalse(filtered.selectedKinds.contains(DesktopNativeSourceDocumentCodec.recordKind))
        XCTAssertTrue(filtered.records.allSatisfy { $0.date != nil })
        for platform in DesktopNativeSourceDocument.Platform.allCases {
            let native = try snapshot.projectWithSensitiveNativeEvidence(
                platform: platform, allowSensitiveContent: true,
                scope: .init(selectedIDs: ["native-source/\(platform.rawValue)/\(source.path)"])
            )
            XCTAssertEqual(native.records.count, 1)
            XCTAssertEqual(native.nativeEvidence?.platform, platform)
        }
    }

    func testAggregateBudget_AccountsForOriginalSourcesAndExactBase64PlusMixedEnvelopeOverhead() throws {
        let maximum = DataMigrationArchivePolicy.maximumJSONBytes
        try DesktopVocabularyArchiveSource.Snapshot.requireSensitiveBudget(
            sourceBytes: 3, encodedHeaderBytes: maximum - 7, nativeBytes: 3
        )
        XCTAssertThrowsError(try DesktopVocabularyArchiveSource.Snapshot.requireSensitiveBudget(
            sourceBytes: 3, encodedHeaderBytes: maximum - 6, nativeBytes: 3
        ))
        XCTAssertThrowsError(try DesktopVocabularyArchiveSource.Snapshot.requireSensitiveBudget(
            sourceBytes: .max, encodedHeaderBytes: 0, nativeBytes: 0
        ))
        let root = try directory()
        try populate(root)
        let raw = Data([0xFF, 0xFF, 0xFF, 1])
        try write(raw, path: source.path, root: root)
        let snapshot = try collect(root)
        let mixed = try snapshot.projectWithSensitiveNativeEvidence(platform: platform, allowSensitiveContent: true)
        let canonical = mixed.records.filter { $0.kind != DesktopNativeSourceDocumentCodec.recordKind }
        let empty = try DesktopNativeSourceDocumentCodec.capture(
            platform: platform, source: source, rawBytes: Data(), allowSensitiveContent: true
        )
        let placeholder = try DesktopNativeSourceDocumentCodec.project([empty], allowSensitiveContent: true)
        let headerSize = try DataMigrationCoding.encoder.encode(canonical + placeholder.records).count
        let encodedSize = try DataMigrationCoding.encoder.encode(mixed.records).count
        XCTAssertEqual(encodedSize, headerSize + 4 * ((raw.count + 2) / 3))
        let sourceSize = snapshot.collections.reduce(UInt64(raw.count)) { $0 + UInt64($1.source.data?.count ?? 0) }
        try DesktopVocabularyArchiveSource.Snapshot.requireSensitiveBudget(
            sourceBytes: sourceSize, encodedHeaderBytes: UInt64(headerSize), nativeBytes: UInt64(raw.count)
        )
    }
}

private final class SensitiveFixtureHasher: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws {
        throw LocalModelDigestError.unavailable("Identified fixture must not require hashing.")
    }
    func finish() throws -> String {
        throw LocalModelDigestError.unavailable("Identified fixture must not require hashing.")
    }
}
