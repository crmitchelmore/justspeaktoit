import Foundation
import XCTest
@testable import SpeakCore

final class HistoryRequestFailureRetentionTests: XCTestCase {
    func testLegacyAndAdmissionInitializersKeepNilFailureBytes() throws {
        let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = HistoryRecord(id: id, createdAt: date, rawTranscription: "owned", recordingDuration: 1)
        let explicit = HistoryRecord(id: id, createdAt: date, rawTranscription: "owned", recordingDuration: 1,
                                     requestFailure: nil)
        XCTAssertEqual(try self.encode(legacy), try self.encode(explicit))
        let admission = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        let oldAdmission = HistoryRecord(id: id, createdAt: date, recordingDuration: 1, requestContext: admission)
        let newAdmission = HistoryRecord(id: id, createdAt: date, recordingDuration: 1,
                                         requestContext: admission, requestFailure: nil)
        XCTAssertEqual(try self.encode(oldAdmission), try self.encode(newAdmission))
        XCTAssertNil(try self.object(self.encode(oldAdmission))["requestFailure"])
        XCTAssertEqual(HistoryRecord.currentSchemaVersion, 1)
    }

    func testOnlyNewFailureFieldIsLossyInBothCodecsWhileOldFieldsStayStrict() throws {
        let local = try self.object(self.encode(HistoryRecordFixtures.richMac().historyRecord))
        let native: [String: Any] = ["id": UUID().uuidString, "createdAt": 0, "transcription": "owned",
                                     "model": "owned", "duration": 1, "wordCount": 1]
        for original in [local, native] {
            let old = try self.decode(original)
            for invalid: Any in ["private unknown failure", 7, ["stage": "future"], NSNull()] {
                var object = original
                object["requestFailure"] = invalid
                let restored = try self.decode(object)
                XCTAssertEqual(restored, old)
                XCTAssertEqual(try self.encode(restored), try self.encode(old))
            }
            var invalidOld = original
            invalidOld["requestFailure"] = "invalid"
            invalidOld[original["schemaVersion"] == nil ? "duration" : "recordingDuration"] = "invalid old field"
            XCTAssertThrowsError(try self.decode(invalidOld))
        }
    }

    func testFailureDecoderKeepsOnlyFiniteValuesAndBoundedHTTPStatus() throws {
        let canary = "PRIVATE_FAILURE_user@example.com/path?key=secret"
        let failure: [String: Any] = ["stage": "finalization", "code": "timeout", "domain": "application",
                                      "httpStatus": 999, "message": canary, "url": canary]
        var object = try self.object(self.encode(HistoryRecord(recordingDuration: 1)))
        object["requestFailure"] = failure
        let record = try self.decode(object)
        XCTAssertEqual(record.requestFailure, .init(stage: .finalization, code: .timeout, domain: .application))
        XCTAssertNil(record.requestFailure?.httpStatus)
        let serialized = try XCTUnwrap(String(data: self.encode(record), encoding: .utf8))
        XCTAssertFalse(serialized.contains(canary))
        var unknownDomain = failure
        unknownDomain["domain"] = canary
        object["requestFailure"] = unknownDomain
        XCTAssertNil(try self.decode(object).requestFailure)
    }

    func testFailureEqualityCopiesAndMacRefusalPreserveExistingRichMetadata() throws {
        let old = HistoryRecordFixtures.richMac().historyRecord
        var object = try self.object(self.encode(old))
        object["requestFailure"] = ["stage": "finalization", "code": "timeout", "domain": "application"]
        let failed = try self.decode(object)
        let same = try self.decode(self.object(self.encode(failed)))
        XCTAssertNotEqual(failed, old)
        XCTAssertEqual(failed, same)
        XCTAssertEqual(failed.hashValue, same.hashValue)
        XCTAssertEqual(Set([old, failed, same]).count, 2)
        XCTAssertNil(ApplicationHistoryItem(historyRecord: failed))
        let copied = failed.replacingLocalText(postProcessedTranscription: "polished", errorMessage: nil,
                                               updatedAt: failed.updatedAt)
        XCTAssertEqual(copied.requestFailure, failed.requestFailure)
        XCTAssertEqual(copied.diagnosticContext, failed.diagnosticContext)
        XCTAssertEqual(copied.cost, failed.cost)
        XCTAssertEqual(copied.networkExchanges, failed.networkExchanges)
        XCTAssertEqual(copied.desktopHistory, failed.desktopHistory)
    }

    func testMigrationRedactsFailureAndAdmissionWithoutRemovingUserText() throws {
        var object = try self.object(DataMigrationCoding.encoder.encode(HistoryRecordFixtures.richMac()))
        object["requestFailure"] = ["stage": "finalization", "code": "timeout", "domain": "application"]
        object["requestContext"] = try JSONSerialization.jsonObject(with: self.encode(RequestDiagnosticContext()))
        let value = try DataMigrationCoding.decoder.decode(AnyCodable.self,
                                                           from: JSONSerialization.data(withJSONObject: object))
        let redacted = try DataMigrationHistoryValue.value(value)
        let exported = try self.object(DataMigrationCoding.encoder.encode(redacted))
        XCTAssertNil(exported["requestFailure"])
        XCTAssertNil(exported["requestContext"])
        XCTAssertNil(exported["diagnosticContext"])
        XCTAssertEqual(exported["rawTranscription"] as? String, object["rawTranscription"] as? String)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> HistoryRecord {
        try JSONDecoder().decode(HistoryRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
