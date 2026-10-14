import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationVocabularyInteropTests: XCTestCase {
    func testMacCollections_UseCanonicalDefinitionsWithoutChangingInventoryOrLocations() {
        let mac = MigrationCatalog.collections.filter { $0.category == .vocabulary }
        XCTAssertEqual(mac.map(\.kind), DataMigrationVocabularyCatalog.collections.map(\.kind))
        XCTAssertEqual(mac.map(\.defaultsKey), DataMigrationVocabularyCatalog.collections.map(\.defaultsKey))
        XCTAssertEqual(mac.map(\.path), DataMigrationVocabularyCatalog.collections.map(\.path))
        XCTAssertEqual(MigrationCatalog.collections.map(\.kind),
                       ["modelReference", "profile", "pronunciation", "lexicon", "correction",
                        "ttsUsage", "whisperModel", "streamingModel", "llmModel"])
    }

    func testMacProjectionValidationAndReencoding_RetainExactRawRecords() throws {
        for collection in MigrationCatalog.collections where collection.category == .vocabulary {
            let data = try VocabularyMigrationFixtures.data(kind: collection.kind)
            let mac = try MigrationCatalog.collectionRecords(collection, data: data)
            let shared = try DataMigrationVocabularyCatalog.records(data: data, kind: collection.kind,
                                                                   digest: MigrationCoding.digest)
            XCTAssertEqual(mac, shared)
            XCTAssertEqual(mac.map(\.value), try JSONDecoder().decode([AnyCodable].self, from: data))
            for record in mac {
                XCTAssertNoThrow(try MigrationCatalog.validate(record, category: .vocabulary))
                XCTAssertNoThrow(try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary))
            }
            XCTAssertEqual(try MigrationCoding.encoder.encode(mac), try DataMigrationCoding.encoder.encode(shared))
        }
    }

    func testMacAndSharedValidation_RejectTheSameMalformedRecordVariants() throws {
        for collection in MigrationCatalog.collections where collection.category == .vocabulary {
            let valid = try XCTUnwrap(MigrationCatalog.collectionRecords(
                collection, data: VocabularyMigrationFixtures.data(kind: collection.kind)
            ).first)
            for variant in 0..<4 {
                var record = valid
                var category = MigrationCategory.vocabulary
                if variant == 0 { category = .profiles }
                if variant == 1 { record.id = UUID().uuidString }
                if variant == 2 { record.kind = "inventedStatus" }
                if variant == 3 { record.value = AnyCodable(.object(["id": .string(record.id)])) }
                XCTAssertThrowsError(try MigrationCatalog.validate(record, category: category))
                XCTAssertThrowsError(try DataMigrationVocabularyCatalog.validate(record, category: category))
            }
        }
    }
}
