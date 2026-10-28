import Foundation
import XCTest
@testable import SpeakCore

final class HistoryAdmissionRetentionTests: XCTestCase {
    func testOldRecordInitializerAndExplicitNilKeepExactEncoding() throws {
        let id = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let old = HistoryRecord(id: id, createdAt: date, rawTranscription: "owned", recordingDuration: 1)
        let nilContext = HistoryRecord(id: id, createdAt: date, rawTranscription: "owned", recordingDuration: 1,
                                       requestContext: nil)
        XCTAssertEqual(try self.encoder().encode(old), try self.encoder().encode(nilContext))
        XCTAssertEqual(old, nilContext)
        XCTAssertNil(try self.object(self.encoder().encode(old))["requestContext"])
        XCTAssertEqual(HistoryRecord.currentSchemaVersion, 1)
    }

    func testCanonicalAdmissionRejectsObservedAndRemovesForgedProvider() throws {
        let canary = "PRIVATE_ADMISSION_user@example.com/key/path"
        XCTAssertNil(RequestDiagnosticContext.admissionOnly(.init(provenance: .observedHandoff)))
        var object = try self.object(self.encoder().encode(RequestDiagnosticContext()))
        object["observedProvider"] = ["identifier": "gladia"]
        object["model"] = ["classification": "builtIn", "identifier": canary]
        let decoded = try JSONDecoder().decode(RequestDiagnosticContext.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        let safe = try XCTUnwrap(RequestDiagnosticContext.admissionOnly(decoded))
        XCTAssertNil(safe.observedProvider)
        XCTAssertNil(safe.model.identifier)
        XCTAssertEqual(safe.model.classification, .customOrUnknown)
        let encoded = try XCTUnwrap(String(data: self.encoder().encode(safe), encoding: .utf8))
        XCTAssertFalse(encoded.contains(canary))
    }

    func testOnlyNewOptionalLocalFieldIsLossyWhileOldFieldsRemainStrict() throws {
        let original = HistoryRecordFixtures.richMac().historyRecord
        let old = try self.encoder().encode(original)
        var object = try self.object(old)
        for invalid: Any in ["malformed", 17, ["provenance": "future"], NSNull()] {
            object["requestContext"] = invalid
            let decoded = try JSONDecoder().decode(HistoryRecord.self,
                                                   from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(try self.encoder().encode(decoded), old)
        }
        object["requestContext"] = "malformed"
        object["recordingDuration"] = "invalid old field"
        XCTAssertThrowsError(try JSONDecoder().decode(HistoryRecord.self,
                                                     from: JSONSerialization.data(withJSONObject: object)))
    }

    func testNativeLegacyDecoderRecognizesAdmissionWithoutChangingLegacyDefaults() throws {
        let id = UUID(), context = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        let legacy: [String: Any] = ["id": id.uuidString, "createdAt": 0, "transcription": "owned",
                                      "model": "recorded", "duration": 1, "wordCount": 1]
        var object = legacy
        object["requestContext"] = try JSONSerialization.jsonObject(with: self.encoder().encode(context))
        let record = try JSONDecoder().decode(HistoryRecord.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.requestContext, context)
        XCTAssertEqual(record.createdAt, record.updatedAt)
        XCTAssertEqual(record.originPlatform, "ios")
        object["requestContext"] = "invalid"
        let invalid = try JSONDecoder().decode(HistoryRecord.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        let absent = try JSONDecoder().decode(HistoryRecord.self,
                                              from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(invalid, absent)
    }

    func testEqualityHashCopiesAndMacRefusalIncludeAdmissionWithoutInventedMetadata() throws {
        let old = HistoryRecordFixtures.richMac().historyRecord
        XCTAssertNotNil(ApplicationHistoryItem(historyRecord: old))
        var object = try self.object(self.encoder().encode(old))
        let context = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        object["requestContext"] = try JSONSerialization.jsonObject(with: self.encoder().encode(context))
        let record = try JSONDecoder().decode(HistoryRecord.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        let same = try JSONDecoder().decode(HistoryRecord.self, from: self.encoder().encode(record))
        XCTAssertNotEqual(record, old)
        XCTAssertEqual(record, same)
        XCTAssertEqual(record.hashValue, same.hashValue)
        XCTAssertEqual(Set([record, old, same]).count, 2)
        XCTAssertNil(ApplicationHistoryItem(historyRecord: record), "Unsupported admission must not silently disappear")
        let edited = record.replacingLocalText(postProcessedTranscription: "edited", errorMessage: "owned",
                                               updatedAt: record.updatedAt)
        XCTAssertEqual(edited.requestContext, context)
        XCTAssertEqual(edited.diagnosticContext, record.diagnosticContext)
        XCTAssertEqual(edited.networkExchanges, record.networkExchanges)
    }

    func testMigrationExplicitlyRedactsNewAdmissionKeyAndLegacyDiagnostics() throws {
        var object = try self.object(DataMigrationCoding.encoder.encode(HistoryRecordFixtures.richMac()))
        object["requestContext"] = try JSONSerialization.jsonObject(with: self.encoder().encode(
            RequestDiagnosticContext(model: .project("openai/whisper-1"))
        ))
        let source = try DataMigrationCoding.decoder.decode(AnyCodable.self,
                                                            from: JSONSerialization.data(withJSONObject: object))
        let redacted = try DataMigrationHistoryValue.value(source)
        let exported = try self.object(DataMigrationCoding.encoder.encode(redacted))
        XCTAssertNil(exported["requestContext"])
        XCTAssertNil(exported["diagnosticContext"])
        XCTAssertEqual(exported["rawTranscription"] as? String, object["rawTranscription"] as? String)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
