import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationProfileCatalogInteropTests: XCTestCase {
    func testMacCollection_DelegatesCanonicalRawProfilesWithoutLosingPromptOrFutureFields() throws {
        let collection = try XCTUnwrap(
            MigrationCatalog.collections.first { $0.kind == DataMigrationProfileCatalog.kind }
        )
        XCTAssertEqual(collection.category, DataMigrationProfileCatalog.category)
        XCTAssertEqual(collection.defaultsKey, DataMigrationProfileCatalog.defaultsKey)
        let data = Data("""
        [{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"Profile","polishPrompt":"Exact prompt",
          "matchers":[{"kind":"future","value":"Keep"}],"transcriptionRouting":"future","extra":{"count":0}}]
        """.utf8)
        let mac = try MigrationCatalog.collectionRecords(collection, data: data)
        let shared = try DataMigrationProfileCatalog.records(data: data, digest: MigrationCoding.digest)
        XCTAssertEqual(mac, shared)
        XCTAssertNoThrow(try MigrationCatalog.validate(mac[0], category: .profiles))
        XCTAssertEqual(mac[0].value, try JSONDecoder().decode([AnyCodable].self, from: data)[0])
    }
}
