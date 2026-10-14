import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DataMigrationHistoryIdentityTests: XCTestCase {
    private static let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let variantID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private static let date = Date(timeIntervalSince1970: 1_704_067_200)
    private static let revision = String(repeating: "c", count: 64)

    func testReidentifiedDesktopHistory_ReimportDoesNotCreateAnotherVersion() throws {
        let original = try nativeValue("Original")
        let changed = try nativeValue("Changed")
        let incoming = snapshot([record(changed, revision: Self.revision)])
        let first = try plan(current: snapshot([record(original)]), incoming: incoming)
        XCTAssertEqual(first.records[.history]?.count, 2)
        let materialized = try materialize(first)
        XCTAssertEqual(materialized.records[.history]?.map(\.id), [
            Self.originalID.uuidString, Self.variantID.uuidString
        ])
        let second = try plan(current: materialized, incoming: incoming)
        XCTAssertEqual(second.records[.history], materialized.records[.history])
    }

    func testReidentification_DoesNotEraseUnknownCarrierDifferences() throws {
        let value = try nativeValue("Same text")
        let current = snapshot([record(try futureValue(value, note: "Existing"))])
        let incoming = snapshot([record(try futureValue(value, note: "Imported"), revision: Self.revision)])
        let result = try plan(current: current, incoming: incoming)
        XCTAssertEqual(result.records[.history]?.count, 2)
        let projected = try materialize(result)
        guard case let .object(fields) = projected.records[.history]?.last?.value.storage,
              case let .object(desktop) = fields["desktopHistory"] else {
            return XCTFail("Expected retained desktop metadata.")
        }
        XCTAssertEqual(desktop["futureNote"], .string("Imported"))
    }

    func testRawRecordValidation_StillRejectsMismatchedEnvelopeIdentity() throws {
        var forged = record(try nativeValue("Untrusted"))
        forged.id = Self.variantID.uuidString
        XCTAssertThrowsError(try DesktopMigrationHistory.record(forged, category: .history))
        XCTAssertThrowsError(try DataMigrationHistorySchema.validate(forged, category: .history))
    }

    private func nativeValue(_ text: String) throws -> AnyCodable {
        var native = DesktopRecordingStore.Record(
            id: Self.originalID, audioFilename: "", modelIdentifier: "synthetic/model", createdAt: Self.date
        )
        native.processedText = text
        return try DesktopMigrationHistory.value(native)
    }

    private func futureValue(_ value: AnyCodable, note: String) throws -> AnyCodable {
        guard case var .object(fields) = value.storage,
              case var .object(desktop) = fields["desktopHistory"] else {
            throw DataMigrationError.invalid("Synthetic fixture has no desktop carrier.")
        }
        desktop["futureNote"] = .string(note)
        fields["desktopHistory"] = .object(desktop)
        return AnyCodable(.object(fields))
    }

    private func record(_ value: AnyCodable, revision: String? = nil) -> DataMigrationRecord {
        .init(id: Self.originalID.uuidString, kind: "history", value: value, date: Self.date, revision: revision)
    }

    private func snapshot(_ records: [DataMigrationRecord]) -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [.history], scopes: [:]), records: [.history: records])
    }

    private func plan(
        current: DataMigrationSnapshot, incoming: DataMigrationSnapshot
    ) throws -> DataMigrationSnapshot {
        try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: [.history: .merge], useImported: [],
            digest: { bytes in
                guard bytes == Data("\(Self.originalID.uuidString):\(Self.revision)".utf8) else {
                    throw DataMigrationError.invalid("Unexpected synthetic digest: merge was not idempotent.")
                }
                return String(repeating: "b", count: 64)
            }
        )
    }

    private func materialize(_ planned: DataMigrationSnapshot) throws -> DataMigrationSnapshot {
        var current: [DataMigrationRecord] = []
        for var record in planned.records[.history] ?? [] {
            // Match Mac's application: the canonical helper reidentifies both
            // the application item and its optional native desktop carrier.
            record.value = try DataMigrationHistoryValue.value(record.value, id: record.id)
            let native = try DesktopMigrationHistory.record(record, category: .history)
            current.append(.init(
                id: native.id.uuidString, kind: "history",
                value: try DesktopMigrationHistory.value(native), date: native.createdAt
            ))
        }
        return snapshot(current)
    }
}
