#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import XCTest

@testable import SpeakiOSLib

final class HistoryRecordAdapterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testNativeIOSLegacyEncoder_SharedDecodeAndAdapterRoundTripAreLossless() throws {
        let original = iOSHistoryItem(
            createdAt: self.date, updatedAt: self.date.addingTimeInterval(8),
            transcription: "synthetic ios words", postProcessedTranscription: "", model: "openai/whisper-1",
            duration: 3.75, wordCount: 3, originPlatform: "macos", errorMessage: "Synthetic retry"
        )
        let encoded = try self.encoder().encode(original)
        let record = try self.decoder().decode(HistoryRecord.self, from: encoded)
        XCTAssertEqual(record, original.historyRecord)
        let restored = iOSHistoryItem(historyRecord: record)
        XCTAssertEqual(try self.encoder().encode(restored), encoded, "The existing ten-key schema must not change")
        XCTAssertEqual(record.presentation, original.presentationItem)
        XCTAssertEqual(record.presentation.modelIdentifiers, ["openai/whisper-1"])
        XCTAssertEqual(record.presentation.errorCount, 1)
        XCTAssertEqual(restored.bestText, "")
        XCTAssertFalse(restored.hasPolishedText)
        var old = try self.object(encoded)
        old.removeValue(forKey: "updatedAt")
        old.removeValue(forKey: "originPlatform")
        let legacy = try JSONSerialization.data(withJSONObject: old)
        let oldAdapter = try self.decoder().decode(iOSHistoryItem.self, from: legacy)
        XCTAssertEqual(try self.decoder().decode(HistoryRecord.self, from: legacy), oldAdapter.historyRecord)
    }

    func testEditingIOSAdapter_KeepsErrorAndTimestampSemantics() {
        let record = HistoryRecord(
            createdAt: self.date, updatedAt: self.date, rawTranscription: "raw", recordingDuration: 1,
            model: "model", wordCount: 1, originPlatform: "ios", errorMessage: "First error"
        )
        let adapter = iOSHistoryItem(historyRecord: record)
        let errored = adapter.withError("Second error")
        XCTAssertEqual(errored.updatedAt, self.date)
        XCTAssertEqual(errored.errorMessage, "Second error")
        let polished = errored.withPostProcessed("", updatedAt: self.date.addingTimeInterval(10))
        XCTAssertEqual(polished.transcription, "raw")
        XCTAssertEqual(polished.bestText, "")
        XCTAssertFalse(polished.hasPolishedText)
        XCTAssertNil(polished.errorMessage)
        XCTAssertEqual(polished.updatedAt, self.date.addingTimeInterval(10))
    }

    func testRichDisplayConversion_RetainsSourceOnlyInMemoryIncludingEdits() throws {
        let record = self.richRecord()
        let adapter = iOSHistoryItem(historyRecord: record)
        XCTAssertEqual(adapter.historyRecord, record)
        XCTAssertEqual(adapter.presentationItem, record.iosPresentation)
        XCTAssertEqual(adapter.transcription, "", "The String display adapter must retain a nil raw source separately")
        let polished = adapter.withError("Synthetic retry").withPostProcessed("Polished", updatedAt: self.date)
        XCTAssertNil(polished.errorMessage)
        XCTAssertEqual(polished.wordCount, adapter.wordCount, "Polishing retains the adapter's original word count")
        XCTAssertNil(polished.historyRecord.wordCount, "The source record must not be coerced into the display shape")
        XCTAssertNil(polished.historyRecord.rawTranscription)
        XCTAssertEqual(polished.historyRecord.postProcessedTranscription, "Polished")
        XCTAssertEqual(polished.historyRecord.audioFileURL, record.audioFileURL)
        XCTAssertEqual(polished.historyRecord.networkExchanges, record.networkExchanges)
        XCTAssertEqual(polished.historyRecord.desktopHistory, record.desktopHistory)
        XCTAssertEqual(polished.historyRecord.cost, record.cost)
        let encoded = try self.encoder().encode(adapter)
        let reloaded = try self.decoder().decode(iOSHistoryItem.self, from: encoded)
        XCTAssertNil(reloaded.historyRecord.audioFileURL)
        XCTAssertTrue(reloaded.historyRecord.networkExchanges.isEmpty)
        XCTAssertNil(reloaded.historyRecord.desktopHistory)
        XCTAssertNotEqual(reloaded.historyRecord, record, "Legacy iOS persistence does not promise rich retention")
    }

    func testRichDisplayPresentation_LocalErrorsStayFilterableWithoutDiscardingRichFields() {
        let record = self.richRecord()
        let adapter = iOSHistoryItem(historyRecord: record)
        XCTAssertEqual(adapter.presentationItem.modelIdentifiers, ["legacy/model"])
        XCTAssertEqual(adapter.presentationItem.rawTranscription, "")
        XCTAssertEqual(adapter.presentationItem.cost, 0)
        XCTAssertEqual(adapter.presentationItem.errorCount, 0)
        let errored = adapter.withError("Local display error")
        XCTAssertEqual(errored.presentationItem.errorCount, 1)
        XCTAssertTrue(HistorySearchQuery(includeErrorsOnly: true).matches(errored.presentationItem))
        XCTAssertEqual(errored.historyRecord.modelsUsed, ["legacy/model", "other/model"])
        XCTAssertNil(errored.historyRecord.model)
        XCTAssertEqual(errored.historyRecord.cost, record.cost)
        XCTAssertEqual(errored.historyRecord.networkExchanges, record.networkExchanges)
        XCTAssertTrue(errored.historyRecord.errors.isEmpty)
        let captureErrors = self.richRecord(errors: [.init(phase: .output, message: "Capture diagnostic")])
        let diagnosticAdapter = iOSHistoryItem(historyRecord: captureErrors)
        XCTAssertEqual(diagnosticAdapter.presentationItem.errorCount, 0)
        XCTAssertEqual(diagnosticAdapter.historyRecord.errors.count, 1)
    }

    func testLocalRecordAndError_DoNotExpandNineFieldSyncDisclosure() throws {
        let adapter = iOSHistoryItem(historyRecord: self.richRecord()).withError("Private local error")
        let encoded = try self.encoder().encode(adapter.toSyncable())
        let object = try self.object(encoded)
        XCTAssertEqual(Set(object.keys), Set([
            "id", "createdAt", "updatedAt", "rawTranscription", "postProcessedText", "model",
            "duration", "wordCount", "originPlatform"
        ]))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for localValue in ["Private local error", "synthetic-local", "Private response", "Private metadata"] {
            XCTAssertFalse(text.contains(localValue))
        }
        XCTAssertNil(iOSHistoryItem.fromSyncable(adapter.toSyncable()).errorMessage)
    }

    private func richRecord(errors: [ApplicationHistoryError] = []) -> HistoryRecord {
        HistoryRecord(
            createdAt: self.date, updatedAt: self.date, modelsUsed: ["legacy/model", "other/model"],
            rawTranscription: nil, postProcessedTranscription: "", recordingDuration: 3,
            cost: .init(total: 0.25, currency: "USD"),
            audioFileURL: URL(string: "file:///synthetic-local/recording.wav"),
            networkExchanges: [.init(
                url: URL(string: "https://example.invalid/transcribe")!, method: "POST",
                requestHeaders: [:], requestBodyPreview: "Private request", responseCode: 200,
                responseHeaders: [:], responseBodyPreview: "Private response"
            )],
            errors: errors, desktopHistory: AnyCodable(.object(["local": .string("Private metadata")]))
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
#endif
