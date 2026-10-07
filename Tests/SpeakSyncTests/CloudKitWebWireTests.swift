import Foundation
import XCTest

@testable import SpeakSync

final class CloudKitWebWireTests: XCTestCase {
    func testFieldValuesFollowTheNativeRecordBridgingRules() throws {
        let object: [String: Any] = ["recordName": "synthetic", "recordType": "Synthetic", "fields": [
            "integralDouble": CloudKitWebFixture.field(2.0, "DOUBLE"),
            "fractional": CloudKitWebFixture.field(2.5, "DOUBLE"),
            "one": CloudKitWebFixture.field(1, "INT64"),
            "two": CloudKitWebFixture.field(2, "INT64"),
            "timestamp": CloudKitWebFixture.field(1_800_000_000_125, "TIMESTAMP"),
            "text": CloudKitWebFixture.field("hello", "STRING"),
            "bytes": CloudKitWebFixture.field("AQID", "BYTES"),
            "badBytes": CloudKitWebFixture.field("***", "BYTES"),
            "reference": CloudKitWebFixture.field(["recordName": "other", "action": "NONE"], "REFERENCE"),
            "cleared": ["value": NSNull(), "type": "STRING"]
        ]]
        let record = try JSONDecoder().decode(CloudKitWebRecord.self, from: CloudKitWebFixture.data(object))

        XCTAssertEqual(record.int(forKey: "integralDouble"), 2)
        XCTAssertNil(record.int(forKey: "fractional"))
        XCTAssertEqual(record.double(forKey: "two"), 2)
        XCTAssertEqual(record.bool(forKey: "one"), true)
        XCTAssertNil(record.bool(forKey: "two"))
        XCTAssertEqual(record.date(forKey: "timestamp"), Date(timeIntervalSince1970: 1_800_000_000.125))
        XCTAssertNil(record.date(forKey: "text"), "no reads across field types")
        XCTAssertNil(record.string(forKey: "timestamp"))
        XCTAssertEqual(record.data(forKey: "bytes"), Data([1, 2, 3]))
        XCTAssertNil(record.data(forKey: "badBytes"))
        XCTAssertEqual(record.fields["reference"]?.value, .unsupported(type: "REFERENCE"))
        XCTAssertTrue(record.hasValue(forKey: "reference"))
        XCTAssertFalse(record.hasValue(forKey: "cleared"))
        XCTAssertFalse(record.deleted)
    }

    func testRequestFieldsCarryExplicitTypesMillisecondTimestampsAndNulls() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ value: SyncFieldValue?) throws -> String {
            String(data: try encoder.encode(CloudKitWebFieldPayload(value: value)), encoding: .utf8) ?? ""
        }

        XCTAssertEqual(try json(.string("hello")), #"{"type":"STRING","value":"hello"}"#)
        XCTAssertEqual(try json(.int64(7)), #"{"type":"INT64","value":7}"#)
        XCTAssertEqual(try json(.double(2.5)), #"{"type":"DOUBLE","value":2.5}"#)
        XCTAssertEqual(
            try json(.timestamp(Date(timeIntervalSince1970: 1_800_000_000.125))),
            #"{"type":"TIMESTAMP","value":1800000000125}"#
        )
        XCTAssertEqual(try json(.bytes(Data([1, 2, 3]))), #"{"type":"BYTES","value":"AQID"}"#)
        XCTAssertEqual(try json(nil), #"{"value":null}"#)
    }

    func testTimestampsRoundToTheNearestMillisecondAndRoundTripExactly() throws {
        let precise = Date(timeIntervalSince1970: 1_800_000_000.125)
        XCTAssertEqual(CloudKitWebTimestamp.milliseconds(precise), 1_800_000_000_125)
        XCTAssertEqual(CloudKitWebTimestamp.date(milliseconds: 1_800_000_000_125), precise)
        XCTAssertEqual(CloudKitWebTimestamp.milliseconds(Date(timeIntervalSince1970: 1.0006)), 1_001)
        XCTAssertNil(CloudKitWebTimestamp.milliseconds(Date(timeIntervalSince1970: .infinity)))
    }

    func testCreateOmitsEmptyFieldsAndUpdateClearsOnlyWhatTheServerHolds() throws {
        let entry = SyncWireFixture.entry(raw: nil, processed: "processed")
        let assignments = HistoryRecordCodec.assignments(for: entry)
        let type = SyncSchema.History.recordType
        let create = try CloudKitWebRecordWrite.create(recordName: "n", recordType: type, assignments: assignments)
        XCTAssertEqual(create.operationType, .create)
        XCTAssertNil(create.record.recordChangeTag)
        XCTAssertNil(create.record.fields?["rawTranscription"])
        XCTAssertEqual(create.record.fields?.count, 8)

        let existing = try SyncWireFixture.record(name: "n", type: type, tag: "tag-7", assignments: [
            ("rawTranscription", .string("old raw")),
            ("fieldFromANewerApp", .string("kept"))
        ])
        let update = try CloudKitWebRecordWrite.update(existing: existing, recordType: type, assignments: assignments)
        XCTAssertEqual(update.operationType, .update)
        XCTAssertEqual(update.record.recordChangeTag, "tag-7")
        XCTAssertEqual(update.record.fields?["rawTranscription"], CloudKitWebFieldPayload(value: nil))
        XCTAssertEqual(update.record.fields?["postProcessedText"], CloudKitWebFieldPayload(value: .string("processed")))
        XCTAssertNil(update.record.fields?["fieldFromANewerApp"], "fields this client does not write are untouched")
    }

    func testWritesThatCannotBeConditionalOrEncodedAreRefused() throws {
        let untagged = try SyncWireFixture.record(name: "n", type: "TranscriptionHistory", tag: nil, assignments: [])
        XCTAssertThrowsError(try CloudKitWebRecordWrite.update(existing: untagged, recordType: "T", assignments: []))
        let notANumber: SyncRecordFieldAssignments = [("duration", .double(.nan))]
        XCTAssertThrowsError(
            try CloudKitWebRecordWrite.create(recordName: "n", recordType: "T", assignments: notANumber)
        )
        let delete = CloudKitWebRecordWrite.forceDelete(recordName: "n")
        XCTAssertEqual(delete.operationType, .forceDelete)
        XCTAssertNil(delete.record.fields)
        XCTAssertNil(delete.record.recordChangeTag)
    }

    func testErrorDictionariesKeepUnknownCodesAndRetryHints() throws {
        let object: [String: Any] = ["records": [
            ["recordName": "a", "serverErrorCode": "SOME_FUTURE_CODE", "reason": "synthetic"],
            ["recordName": "b", "serverErrorCode": "THROTTLED", "retryAfter": 3],
            ["recordName": "c", "recordType": "T", "recordChangeTag": "t", "deleted": true]
        ]]
        let response = try JSONDecoder().decode(CloudKitWebRecordsResponse.self, from: CloudKitWebFixture.data(object))

        guard case .failure(let unknown) = response.records[0], case .failure(let throttled) = response.records[1],
              case .record(let deleted) = response.records[2] else {
            return XCTFail("Unexpected results \(response.records)")
        }
        XCTAssertEqual(unknown.code.rawValue, "SOME_FUTURE_CODE")
        XCTAssertEqual(throttled.retryAfter, 3)
        XCTAssertEqual(throttled.recordName, "b")
        XCTAssertTrue(deleted.deleted)
        XCTAssertEqual(response.records.map(\.recordName), ["a", "b", "c"])
    }
}
