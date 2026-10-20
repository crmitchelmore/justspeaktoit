import Foundation
import SpeakCore
import XCTest

final class DataMigrationValidationCancellationTests: XCTestCase {
    func testPrecancelledValidation_DoesNotCallValidator() {
        var calls = 0
        XCTAssertThrowsError(try DataMigrationRecordValidation.validate(
            snapshot(), checkCancellation: { throw CancellationError() }, recordValidator: { _, _ in calls += 1 }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 0)
    }

    func testValidatorCancellation_StopsBeforeNextRecordInsteadOfReturningPartialData() {
        var calls = 0
        XCTAssertThrowsError(try DataMigrationRecordValidation.validate(
            snapshot(), checkCancellation: {}, recordValidator: { _, _ in
                calls += 1
                throw CancellationError()
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testCancellationAfterValidRecord_StopsBeforeNextRecord() {
        var cancelled = false
        var calls = 0
        XCTAssertThrowsError(try DataMigrationRecordValidation.validate(
            snapshot(), checkCancellation: { if cancelled { throw CancellationError() } },
            recordValidator: { _, _ in
                calls += 1
                cancelled = true
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testCancellationAfterInvalidRecord_DoesNotReturnDamagedPartialSnapshot() {
        var cancelled = false
        var calls = 0
        XCTAssertThrowsError(try DataMigrationRecordValidation.validate(
            snapshot(), checkCancellation: { if cancelled { throw CancellationError() } },
            recordValidator: { _, _ in
                calls += 1
                cancelled = true
                throw DataMigrationError.invalid("Synthetic invalid item")
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testEmptyValidation_ChecksCancellationBeforeReturning() {
        var checks = 0
        let incoming = DataMigrationSnapshot(manifest: .init(categories: [.history], scopes: [:]), records: [:])
        XCTAssertThrowsError(try DataMigrationRecordValidation.validate(
            incoming, checkCancellation: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }, recordValidator: { _, _ in XCTFail("Missing categories contain no records to validate.") }
        )) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(checks, 2)
    }

    func testRealTaskCancellation_IsNotConvertedIntoAnInvalidRecordNotice() async {
        let incoming = snapshot()
        let outcome = await Task.detached {
            var calls = 0
            do {
                _ = try DataMigrationRecordValidation.validate(
                    incoming, checkCancellation: { try Task.checkCancellation() },
                    recordValidator: { _, _ in
                        calls += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                )
                return (calls, false)
            } catch {
                return (calls, error is CancellationError)
            }
        }.value
        XCTAssertEqual(outcome.0, 1)
        XCTAssertTrue(outcome.1)
    }

    func testUncancelledValidation_MatchesLegacyScopeAndDamagePreservation() throws {
        var incoming = snapshot()
        incoming.manifest.categories.append(.settings)
        incoming.manifest.scopes["history"] = .init(selectedIDs: ["one", "two"])
        incoming.records[.history]?.append(.init(id: "outside", kind: "history", value: AnyCodable(.string("text"))))
        incoming.notices = ["Existing notice"]
        incoming.files = ["recordings/owned.wav": URL(fileURLWithPath: "/synthetic/staged.wav")]
        let validator: (DataMigrationRecord, DataMigrationCategory) throws -> Void = { record, _ in
            if record.id == "two" { throw DataMigrationError.invalid("Synthetic invalid item") }
        }
        let legacy = DataMigrationRecordValidation.validate(incoming, recordValidator: validator)
        let checked = try DataMigrationRecordValidation.validate(
            incoming, checkCancellation: {}, recordValidator: validator
        )
        XCTAssertEqual(checked.records, legacy.records)
        XCTAssertEqual(checked.notices, legacy.notices)
        XCTAssertEqual(checked.files, incoming.files)
        XCTAssertEqual(checked.records[.history]?.map(\.id), ["one"])
        XCTAssertNil(checked.records[.settings])
        XCTAssertEqual(checked.notices.count, 3)
        XCTAssertEqual(incoming.records[.history]?.count, 3)
    }

    private func snapshot() -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [.history], scopes: [:]), records: [.history: [
            .init(id: "one", kind: "history", value: AnyCodable(.string("First synthetic item"))),
            .init(id: "two", kind: "history", value: AnyCodable(.string("Second synthetic item")))
        ]])
    }
}
