import Foundation
import XCTest

@testable import SpeakCore

final class HistoryRecordTests: XCTestCase {
    func testRichMacFixture_PreservesEveryLocalFieldAndLegacyEncoding() throws {
        let fixture = try self.fixture("mac-rich")
        let original = try HistoryRecordFixtures.decoder().decode(ApplicationHistoryItem.self, from: fixture)
        let record = try self.decode(fixture)
        XCTAssertEqual(original, HistoryRecordFixtures.richMac())
        XCTAssertEqual(record, original.historyRecord)
        let restored = try XCTUnwrap(ApplicationHistoryItem(historyRecord: record))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(try HistoryRecordFixtures.encoder().encode(restored), fixture)
        XCTAssertEqual(record.cost?.total, Decimal(string: "0.123456789"))
        XCTAssertEqual(record.audioFileURL?.absoluteString, "file:///synthetic-local/recording.wav")
        XCTAssertEqual(record.latency?.firstPartialMs, 234)
        XCTAssertEqual(record.phaseTimestamps?.transcriptionDurationMs, 5_000)
        XCTAssertEqual(record.personalCorrections?.applied.first?.canonical, "Synthetic")
        XCTAssertEqual(record.desktopHistory, original.desktopHistory)
        XCTAssertEqual(record.presentation.modelIdentifiers, ["deepgram/nova-3", "synthetic/polish"])
        XCTAssertEqual(record.presentation.cost, original.cost?.total)
        XCTAssertEqual(record.presentation.errorCount, 1)
        XCTAssertEqual(try self.decode(HistoryRecordFixtures.encoder().encode(record)), record)
    }

    func testMinimalMacFixture_PreservesNilEmptyTextAndDeprecatedModelsFallback() throws {
        let fixture = try self.fixture("mac-minimal")
        let original = try HistoryRecordFixtures.decoder().decode(ApplicationHistoryItem.self, from: fixture)
        let record = try self.decode(fixture)
        XCTAssertEqual(original, HistoryRecordFixtures.minimalMac())
        XCTAssertNil(record.rawTranscription)
        XCTAssertEqual(record.postProcessedTranscription, "")
        XCTAssertEqual(record.bestText, "")
        XCTAssertFalse(record.hasPolishedText)
        XCTAssertEqual(record.presentation.modelIdentifiers, ["legacy/model"])
        XCTAssertEqual(ApplicationHistoryItem(historyRecord: record), original)
        XCTAssertEqual(try self.decode(HistoryRecordFixtures.encoder().encode(record)), record)
        var old = try self.object(fixture)
        old.removeValue(forKey: "modelUsages")
        let earlier = try self.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(earlier.modelUsages.isEmpty)
        XCTAssertEqual(earlier.modelsUsed, ["legacy/model"])
        XCTAssertEqual(earlier.presentation.modelIdentifiers, ["legacy/model"])
    }

    func testOldIOSFixture_DefaultsDatesAndOriginWithoutInventingCaptureContext() throws {
        let record = try self.decode(self.fixture("ios-legacy"))
        XCTAssertEqual(record.createdAt, HistoryRecordFixtures.date)
        XCTAssertEqual(record.updatedAt, record.createdAt)
        XCTAssertEqual(record.originPlatform, "ios")
        XCTAssertEqual(record.model, "openai/whisper-1")
        XCTAssertEqual(record.wordCount, 3)
        XCTAssertEqual(record.rawTranscription, "synthetic ios words")
        XCTAssertNil(record.postProcessedTranscription)
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(record.trigger)
        XCTAssertNil(record.phaseTimestamps)
        XCTAssertTrue(record.events.isEmpty)
        XCTAssertTrue(record.networkExchanges.isEmpty)
        XCTAssertNil(ApplicationHistoryItem(historyRecord: record), "A Mac conversion must not discard iOS fields")
    }

    func testCurrentIOSFixture_UsesKeysRatherThanOriginForItsPresentation() throws {
        let record = try self.decode(self.fixture("ios-current"))
        XCTAssertEqual(record.originPlatform, "macos")
        XCTAssertEqual(record.updatedAt, HistoryRecordFixtures.date.addingTimeInterval(8))
        XCTAssertEqual(record.postProcessedTranscription, "")
        XCTAssertEqual(record.bestText, "")
        XCTAssertEqual(record.errorMessage, "Synthetic retry")
        XCTAssertEqual(record.presentation.modelIdentifiers, ["openai/whisper-1"])
        XCTAssertEqual(record.presentation.errorCount, 1)
        XCTAssertEqual(record.presentation.cost, 0)
        let encoded = try HistoryRecordFixtures.encoder().encode(record)
        XCTAssertEqual(try self.object(encoded)["schemaVersion"] as? Int, 1)
        XCTAssertNil(try self.object(encoded)["transcription"], "New local encodings use explicit shared keys")
        XCTAssertEqual(try self.decode(encoded), record)
    }

    func testDateCodingStrategy_RemainsOwnedByTheCaller() throws {
        let record = HistoryRecordFixtures.richMac().historyRecord
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(HistoryRecord.self, from: data), record)
    }

    func testExplicitVersion_RejectsUnknownOrMalformedMarkersBeforeLegacyDecoding() throws {
        for name in ["mac-rich", "ios-current"] {
            var object = try self.object(self.fixture(name))
            object["schemaVersion"] = 2
            XCTAssertThrowsError(try self.decode(JSONSerialization.data(withJSONObject: object))) { error in
                guard case .dataCorrupted(let context) = error as? DecodingError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(context.debugDescription.contains("Unsupported local history schema version: 2"))
            }
            for malformed: Any in [NSNull(), "1", true] {
                object["schemaVersion"] = malformed
                XCTAssertThrowsError(try self.decode(JSONSerialization.data(withJSONObject: object)))
            }
        }
    }

    func testMalformedRequiredIdentityDateAndIOSFields_AreNotDefaulted() throws {
        let shapes = [
            ("mac-rich", ["id", "createdAt", "updatedAt", "recordingDuration"]),
            ("ios-current", ["id", "createdAt", "transcription", "model", "duration", "wordCount"])
        ]
        for (name, keys) in shapes {
            for key in keys {
                var object = try self.object(self.fixture(name))
                object.removeValue(forKey: key)
                XCTAssertThrowsError(try self.decode(JSONSerialization.data(withJSONObject: object)), "\(name): \(key)")
            }
        }
    }

    func testAbsentDiagnostics_DoNotInventAMacTriggerOrRecordingEvent() throws {
        var object = try self.object(self.fixture("mac-minimal"))
        for key in ["trigger", "phaseTimestamps", "events", "networkExchanges"] { object.removeValue(forKey: key) }
        let record = try self.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(record.trigger)
        XCTAssertNil(record.phaseTimestamps)
        XCTAssertTrue(record.events.isEmpty)
        XCTAssertTrue(record.networkExchanges.isEmpty)
        XCTAssertNil(ApplicationHistoryItem(historyRecord: record))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/HistoryRecord"
        ))
        return try Data(contentsOf: url)
    }

    private func decode(_ data: Data) throws -> HistoryRecord {
        try HistoryRecordFixtures.decoder().decode(HistoryRecord.self, from: data)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
