import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationHistoryInteropTests: XCTestCase {
    func testMacHistoryAliases_EncodeAndValidateThroughCanonicalSchema() throws {
        let item: ApplicationHistoryItem = HistoryItem.placeholder
        let value = try MigrationCoding.value(item)
        let record = MigrationRecord(id: item.id.uuidString, kind: "history", value: value, date: item.createdAt)
        XCTAssertEqual(try DataMigrationHistorySchema.validate(record, category: .history).id, item.id)
        XCTAssertNoThrow(try MigrationCatalog.validate(record, category: .history))
        let native = try DataMigrationCoding.decode(ApplicationHistoryItem.self, value)
        let mac = try MigrationCoding.decode(HistoryItem.self, value)
        XCTAssertEqual(native, mac)
        XCTAssertEqual(try MigrationCoding.encoder.encode(mac), try DataMigrationCoding.encoder.encode(native))
        XCTAssertEqual(mac.presentationItem.originPlatform, "macos")
    }

    func testMacCatalogAndSharedSchema_RejectTheSameIdentityDateAndCategoryMismatches() throws {
        let item = HistoryItem.placeholder
        let value = try MigrationCoding.value(item)
        for variant in 0..<3 {
            var record = MigrationRecord(id: item.id.uuidString, kind: "history", value: value, date: item.createdAt)
            var category = MigrationCategory.history
            if variant == 0 { record.id = UUID().uuidString }
            if variant == 1 { record.date = nil }
            if variant == 2 { category = .recordings }
            XCTAssertThrowsError(try MigrationCatalog.validate(record, category: category))
            XCTAssertThrowsError(try DataMigrationHistorySchema.validate(record, category: category))
        }
    }
}
