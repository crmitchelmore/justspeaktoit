import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest
@testable import SpeakApp

@MainActor
final class VocabularyArchiveSourceInteropTests: XCTestCase {
    func testStrictNativeRawCollection_MatchesActualMacProjectionAndValidation() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for definition in DataMigrationVocabularyCatalog.collections {
            let file = root.appendingPathComponent(definition.desktopPath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try VocabularyMigrationFixtures.data(kind: definition.kind).write(to: file)
        }
        let digests = LocalModelDigestProvider(name: "Mac canonical vocabulary test") {
            MacVocabularyArchiveFixtureHasher()
        }
        let source = try DesktopVocabularyArchiveSource.collect(appDirectory: root, digests: digests)
        for native in source.collections {
            let mac = try XCTUnwrap(MigrationCatalog.collections.first {
                $0.category == .vocabulary && $0.kind == native.definition.kind
            })
            let records = try MigrationCatalog.collectionRecords(mac, data: XCTUnwrap(native.source.data))
            XCTAssertEqual(records, native.records)
            XCTAssertEqual(try MigrationCoding.encoder.encode(records),
                           try DataMigrationCoding.encoder.encode(XCTUnwrap(native.records)))
            for record in records {
                try MigrationCatalog.validate(record, category: .vocabulary)
            }
        }
        let partial = try source.projectCompatibleKinds()
        XCTAssertFalse(partial.isCompleteCategory)
        XCTAssertFalse(partial.scope.isComplete)
        XCTAssertEqual(partial.selectedKinds,
                       Set(MigrationCatalog.collections.filter { $0.category == .vocabulary }.map(\.kind)))
    }
}

private final class MacVocabularyArchiveFixtureHasher: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws {
        throw LocalModelDigestError.unavailable("Identified fixture unexpectedly required hashing.")
    }
    func finish() throws -> String {
        throw LocalModelDigestError.unavailable("Identified fixture unexpectedly required hashing.")
    }
}
