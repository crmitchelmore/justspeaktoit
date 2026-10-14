import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopVocabularyMigrationSnapshotTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Constant fixture digest, not a hash implementation") {
        VocabularyFixtureHasher()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ data: Data, path: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func testCollector_RetainsAllRawValuesOrderUnknownFieldsAndSourceBytes() throws {
        let root = try directory()
        for definition in DataMigrationVocabularyCatalog.collections {
            try write(VocabularyMigrationFixtures.data(kind: definition.kind), path: definition.desktopPath, root: root)
        }
        let result = try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests)
        XCTAssertEqual(result.map(\.definition), DataMigrationVocabularyCatalog.collections)
        for collection in result {
            let source = try VocabularyMigrationFixtures.data(kind: collection.definition.kind)
            let records = try XCTUnwrap(collection.records)
            XCTAssertEqual(records.map(\.value), try JSONDecoder().decode([AnyCodable].self, from: source))
            XCTAssertEqual(records.map(\.id),
                           [VocabularyMigrationFixtures.firstID, VocabularyMigrationFixtures.secondID])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(collection.definition.desktopPath)), source)
            XCTAssertEqual(try DataMigrationCoding.decoder.decode(
                [DataMigrationRecord].self, from: DataMigrationCoding.encoder.encode(records)
            ), records)
        }
    }

    func testCollector_RetainsDismissedAndExpiredCandidatesUnlikeRuntimeLoad() async throws {
        let root = try directory()
        try write(VocabularyMigrationFixtures.data(kind: "correction"),
                  path: "AutoCorrections/candidates.json", root: root)
        let loaded = try await AutoCorrectionStore(appDirectory: root).load()
        XCTAssertTrue(loaded.isEmpty)
        let collection = try XCTUnwrap(DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests)
            .first(where: { $0.definition.kind == "correction" }))
        let candidates = try XCTUnwrap(collection.records).map {
            try DataMigrationCoding.decode(AutoCorrectionCandidate.self, $0.value)
        }
        XCTAssertEqual(candidates.map(\.dismissed), [true, false])
        XCTAssertEqual(candidates.map(\.seenCount), [1, 1])
        XCTAssertEqual(candidates.first?.lastSeenAt, Date(timeIntervalSince1970: 946_771_200))
    }

    func testMissingVersusEmpty_IsExplicitAndNativeCompositeIsNotInventedAsMacRecord() throws {
        let root = try directory()
        try write(Data("[]".utf8), path: "pronunciation.json", root: root)
        let native = Data("Native-only damaged fixture; not a Mac collection".utf8)
        try write(native, path: DesktopVocabularyMigrationSnapshot.unmappedPreferencePath, root: root)
        let result = try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests)
        XCTAssertEqual(result[0].records, [])
        XCTAssertNil(result[1].records)
        XCTAssertNil(result[2].records)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("vocabulary.json")), native)
        let absent = try DesktopVocabularyMigrationSnapshot.collect(
            appDirectory: root.appendingPathComponent("missing"), digests: digests
        )
        XCTAssertTrue(absent.allSatisfy { $0.records == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    func testDamagedSources_ThrowWithoutProducingSuccessfulEmptyReplacement() throws {
        let root = try directory()
        for source in ["invalid JSON", "{}", "[null]", #"[{"id":"missing-required-fields"}]"#] {
            try write(Data(source.utf8), path: "AutoCorrections/candidates.json", root: root)
            XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AutoCorrections/candidates.json"),
                                      encoding: .utf8), source)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("AutoCorrections/candidates.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AutoCorrections/candidates.json"),
                                                withIntermediateDirectories: false)
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests))
    }

    func testOversizedSource_IsRefusedBeforeReadingSparsePayload() throws {
        let root = try directory()
        let file = root.appendingPathComponent("pronunciation.json")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: DataMigrationArchivePolicy.maximumJSONBytes + 1)
        try handle.close()
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests)) {
            XCTAssertTrue($0.localizedDescription.contains("size limit"))
        }
    }

    func testCancellation_InterruptsChunkedReadAndPreservesSource() throws {
        let root = try directory()
        let bytes = Data(String(repeating: "x", count: 200_000).utf8)
        try write(bytes, path: "pronunciation.json", root: root)
        var checks = 0
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(
            appDirectory: root, digests: digests, checkCancellation: {
                checks += 1
                if checks == 7 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 7)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pronunciation.json")), bytes)
    }

    func testSourceReplacementDuringRead_IsReported() throws {
        let root = try directory()
        try write(VocabularyMigrationFixtures.data(kind: "pronunciation"), path: "pronunciation.json", root: root)
        var checks = 0
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(
            appDirectory: root, digests: digests, checkCancellation: {
                checks += 1
                if checks == 4 { try Data("[]".utf8).write(to: root.appendingPathComponent("pronunciation.json")) }
            }
        )) { XCTAssertTrue($0.localizedDescription.contains("changed")) }
    }

    func testCancellation_InterruptsPerRecordValidationWithoutChangingSource() throws {
        let root = try directory()
        let source = try VocabularyMigrationFixtures.data(kind: "pronunciation")
        try write(source, path: "pronunciation.json", root: root)
        var checks = 0
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(
            appDirectory: root, digests: digests, checkCancellation: {
                checks += 1
                if checks == 14 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 14)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pronunciation.json")), source)
    }

    func testCancelledOwnedTask_DefaultCancellationCheckPreventsCollection() async throws {
        let root = try directory()
        let digests = digests
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests)
        }
        do {
            _ = try await worker.value
            XCTFail("A cancelled owned worker must not produce a successful snapshot.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    #if !os(Windows)
    func testUnreadableSource_IsAnErrorNotMissingOrEmpty() throws {
        guard NSUserName() != "root" else { throw XCTSkip("Permission denial requires a non-root test process.") }
        let root = try directory()
        try write(Data("[]".utf8), path: "pronunciation.json", root: root)
        let file = root.appendingPathComponent("pronunciation.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests))
    }

    func testHardLinkedSource_IsNotTreatedAsOwned() throws {
        let root = try directory()
        let external = try directory()
        let source = external.appendingPathComponent("source.json")
        try Data("[]".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("pronunciation.json"))
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests))
        XCTAssertEqual(try Data(contentsOf: source), Data("[]".utf8))
    }

    func testLinkedSourcesAndDirectories_AreNotFollowed() throws {
        let root = try directory()
        let external = try directory()
        let source = external.appendingPathComponent("source.json")
        try Data("[]".utf8).write(to: source)
        let link = root.appendingPathComponent("pronunciation.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("PersonalLexicon"),
                                                   withDestinationURL: external)
        XCTAssertThrowsError(try DesktopVocabularyMigrationSnapshot.collect(appDirectory: root, digests: digests))
    }
    #endif
}

private final class VocabularyFixtureHasher: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws {}
    func finish() throws -> String { String(repeating: "a", count: 64) }
}
