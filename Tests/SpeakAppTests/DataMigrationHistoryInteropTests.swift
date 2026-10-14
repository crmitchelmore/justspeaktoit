import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationHistoryInteropTests: XCTestCase {
    func testNativeCarrier_SurvivesMacHistoryAndMigrationRedaction() throws {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "private.wav", modelIdentifier: "openai/whisper-1",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200.625)
        )
        record.recordedDuration = 2.5
        record.processedText = "Synthetic portable transcript"
        record.languageIdentifier = "en"
        let native = try DesktopMigrationHistory.value(record)
        let mac = try MigrationCoding.decode(HistoryItem.self, native)
        let exported = try mac.migrationValue(audioOnly: false)
        XCTAssertEqual(exported, native)
        let restored = try DesktopMigrationHistory.record(
            .init(id: mac.id.uuidString, kind: "history", value: exported, date: mac.createdAt), category: .history
        )
        XCTAssertEqual(restored.createdAt, record.createdAt)
        XCTAssertEqual(restored.languageIdentifier, "en")
        XCTAssertEqual(restored.processedText, record.processedText)
        XCTAssertFalse(restored.isSyncedCopy)
    }

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
