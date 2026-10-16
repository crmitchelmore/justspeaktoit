import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

final class DataMigrationVocabularyCatalogTests: XCTestCase {
    func testCollections_RetainMacKindsLocationsAndOrder() {
        let definitions = DataMigrationVocabularyCatalog.collections
        XCTAssertEqual(definitions.map(\.kind), ["pronunciation", "lexicon", "correction"])
        XCTAssertEqual(definitions.map(\.defaultsKey), ["pronunciationDictionary", nil, nil])
        XCTAssertEqual(definitions.map(\.path),
                       [nil, "PersonalLexicon/lexicon.json", "AutoCorrections/candidates.json"])
        XCTAssertEqual(definitions.map(\.desktopPath),
                       ["pronunciation.json", "PersonalLexicon/lexicon.json", "AutoCorrections/candidates.json"])
    }

    func testRawProjection_RetainsOpaqueValuesIdentityOrderAndMacDates() throws {
        for collection in DataMigrationVocabularyCatalog.collections {
            let data = try VocabularyMigrationFixtures.data(kind: collection.kind)
            let raw = try JSONDecoder().decode([AnyCodable].self, from: data)
            let records = try DataMigrationVocabularyCatalog.records(data: data, kind: collection.kind) { _ in
                XCTFail("A known payload identifier must not be replaced by a digest.")
                return "unexpected"
            }
            XCTAssertEqual(records.map(\.id),
                           [VocabularyMigrationFixtures.firstID, VocabularyMigrationFixtures.secondID])
            XCTAssertEqual(records.map(\.value), raw)
            for record in records {
                try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary)
                let expectedDate = collection.kind == "lexicon" ? Date(timeIntervalSince1970: 1_704_067_200) : nil
                XCTAssertEqual(record.date, expectedDate)
                XCTAssertNil(record.file)
                XCTAssertNil(record.digest)
                XCTAssertNil(record.revision)
            }
            XCTAssertEqual(try DataMigrationCoding.decoder.decode(
                [DataMigrationRecord].self, from: DataMigrationCoding.encoder.encode(records)
            ), records)
        }
    }

    func testFallbackIdentifier_UsesCanonicalPayloadEncodingWithoutInventingDates() throws {
        let data = Data(#"[{"future":{"nested":[true,null,17]}}]"#.utf8)
        var supplied: Data?
        let records = try DataMigrationVocabularyCatalog.records(data: data, kind: "correction") {
            supplied = $0
            return "fixture-digest"
        }
        XCTAssertEqual(records.first?.id, "fixture-digest")
        XCTAssertEqual(supplied, try DataMigrationCoding.encoder.encode(XCTUnwrap(records.first?.value)))
        XCTAssertNil(records.first?.date)
        let record = try XCTUnwrap(records.first)
        XCTAssertThrowsError(try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary))
    }

    func testValidation_RejectsUnknownKindsWrongCategoryIdentityAndDamagedTypedValues() throws {
        let records = try DataMigrationVocabularyCatalog.records(
            data: VocabularyMigrationFixtures.data(kind: "correction"), kind: "correction", digest: { _ in "" }
        )
        let valid = try XCTUnwrap(records.first)
        XCTAssertThrowsError(try DataMigrationVocabularyCatalog.validate(valid, category: .history))
        for change in 0..<4 {
            var record = valid
            if change == 0 { record.id = "" }
            if change == 1 { record.id = UUID().uuidString }
            if change == 2 { record.kind = "inventedCandidateStatus" }
            if change == 3 { record.value = AnyCodable(.object(["id": .string(record.id)])) }
            XCTAssertThrowsError(try DataMigrationVocabularyCatalog.validate(record, category: .vocabulary))
        }
    }

    func testCancellation_PropagatesDuringRawRecordProjection() throws {
        var checks = 0
        XCTAssertThrowsError(try DataMigrationVocabularyCatalog.records(
            data: VocabularyMigrationFixtures.data(kind: "correction"), kind: "correction", digest: { _ in "" },
            checkCancellation: {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
    }
}
