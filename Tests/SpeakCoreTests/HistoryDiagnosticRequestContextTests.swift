import Foundation
import XCTest

@testable import SpeakCore

final class HistoryDiagnosticRequestContextTests: XCTestCase {
    func testOriginalInitializerAndLegacyJSONKeepRequestContextMissing() throws {
        let legacy = self.diagnostic()
        XCTAssertNil(legacy.requestContext)
        let data = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["requestContext"])
        XCTAssertEqual(try JSONDecoder().decode(ApplicationHistoryDiagnosticContext.self, from: data), legacy)
    }

    func testSafeContextSurvivesActualHistoryAdaptersWithoutIdentityOrContentChanges() throws {
        let original = HistoryRecordFixtures.richMac()
        let request = RequestDiagnosticContext(model: .project("deepgram/nova-3-streaming"), mode: .live)
        let encoder = HistoryRecordFixtures.encoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        var diagnostic = try XCTUnwrap(object["diagnosticContext"] as? [String: Any])
        diagnostic["requestContext"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        object["diagnosticContext"] = diagnostic
        let item = try HistoryRecordFixtures.decoder().decode(
            ApplicationHistoryItem.self, from: JSONSerialization.data(withJSONObject: object)
        )
        let record = item.historyRecord
        let decoded = try HistoryRecordFixtures.decoder().decode(HistoryRecord.self, from: encoder.encode(record))
        let restored = try XCTUnwrap(ApplicationHistoryItem(historyRecord: decoded))
        XCTAssertEqual(restored, item)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.createdAt, original.createdAt)
        XCTAssertEqual(restored.rawTranscription, original.rawTranscription)
        XCTAssertEqual(restored.postProcessedTranscription, original.postProcessedTranscription)
        XCTAssertEqual(restored.audioFileURL, original.audioFileURL)
        XCTAssertEqual(restored.errors, original.errors)
        XCTAssertEqual(restored.diagnosticContext?.requestContext, request)
        XCTAssertEqual(HistoryRecord.currentSchemaVersion, 1)
    }

    func testEqualityIncludesRequestContextAndEqualValuesKeepConsistentHash() throws {
        let original = self.diagnostic()
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = RequestDiagnosticContext(model: .project("deepgram/nova-3-streaming"), mode: .live)
        object["requestContext"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let changed = try JSONDecoder().decode(
            ApplicationHistoryDiagnosticContext.self, from: JSONSerialization.data(withJSONObject: object)
        )
        let same = try JSONDecoder().decode(
            ApplicationHistoryDiagnosticContext.self, from: JSONEncoder().encode(changed)
        )
        XCTAssertNotEqual(original, changed)
        XCTAssertEqual(changed, same)
        XCTAssertEqual(changed.hashValue, same.hashValue)
        XCTAssertEqual(Set([original, changed, same]).count, 2)
    }

    func testMalformedOrFutureOptionalContextCannotDiscardHistoryIdentityOrContent() throws {
        let original = HistoryRecordFixtures.richMac()
        let encoder = HistoryRecordFixtures.encoder()
        let decoder = HistoryRecordFixtures.decoder()
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RequestDiagnosticContext(mode: .live))
        ) as? [String: Any])
        var future = valid
        future["mode"] = "futureMode"
        let invalidValues: [Any] = [future, "malformed context", 17, NSNull()]
        for invalid in invalidValues {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
            var diagnostic = try XCTUnwrap(object["diagnosticContext"] as? [String: Any])
            diagnostic["requestContext"] = invalid
            object["diagnosticContext"] = diagnostic
            let data = try JSONSerialization.data(withJSONObject: object)
            let item = try decoder.decode(ApplicationHistoryItem.self, from: data)
            let record = try decoder.decode(HistoryRecord.self, from: data)
            XCTAssertNil(item.diagnosticContext?.requestContext)
            XCTAssertNil(record.diagnosticContext?.requestContext)
            XCTAssertEqual(item, original)
            XCTAssertEqual(record, original.historyRecord)
            XCTAssertEqual(ApplicationHistoryItem(historyRecord: record), original)
        }
    }

    func testOriginalRequiredDiagnosticFieldsRemainStrictWhenOptionalContextIsInvalid() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(self.diagnostic())
        ) as? [String: Any])
        object["requestContext"] = "malformed context"
        object["processIdentifier"] = "not an integer"
        XCTAssertThrowsError(try JSONDecoder().decode(
            ApplicationHistoryDiagnosticContext.self, from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    private func diagnostic() -> ApplicationHistoryDiagnosticContext {
        ApplicationHistoryDiagnosticContext(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1", appBuild: "2", operatingSystem: "local OS", processIdentifier: 1,
            microphonePermission: "granted", inputDeviceName: "local device", providerLabel: "local provider",
            latencyTier: "local tier", transcriptionMode: "local mode", transcriptionModel: "local model",
            postProcessingModel: "local polish", speedMode: "local speed"
        )
    }
}
