import Foundation
import SpeakCore
import SpeakSync
import XCTest

@testable import SpeakApp

final class HistoryRecordAdapterTests: XCTestCase {
    func testMacAdapter_KeepsLegacyPresentationAndNineFieldSyncDisclosure() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = HistoryItem(
            createdAt: date, updatedAt: date, modelsUsed: ["legacy/model"],
            modelUsages: [.init(modelIdentifier: "actual/model", phase: .transcriptionLive)],
            rawTranscription: "raw text", postProcessedTranscription: "polished text", recordingDuration: 3,
            cost: .init(total: 0.5, currency: "USD"),
            audioFileURL: URL(string: "file:///synthetic-local/recording.wav"),
            networkExchanges: [.init(
                url: URL(string: "https://example.invalid/transcribe")!, method: "POST", requestHeaders: [:],
                requestBodyPreview: "Private request", responseCode: 200, responseHeaders: [:],
                responseBodyPreview: "Private response"
            )],
            events: [], phaseTimestamps: .init(),
            trigger: .init(gesture: .uiButton, hotKeyDescription: "Synthetic button", outputMethod: .none),
            personalCorrections: nil, errors: [.init(phase: .output, message: "Private local error")],
            desktopHistory: AnyCodable(.object(["local": .string("Private metadata")]))
        )
        let restored = try XCTUnwrap(HistoryItem(historyRecord: item.historyRecord))
        XCTAssertEqual(restored, item)
        XCTAssertEqual(item.presentationItem, HistoryPresentationItem(
            id: item.id, createdAt: date, rawTranscription: "raw text", processedTranscription: "polished text",
            modelIdentifiers: ["actual/model"], recordingDuration: 3, cost: 0.5, errorCount: 1, originPlatform: "macos"
        ))
        let data = try JSONEncoder().encode(restored.toSyncable())
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set([
            "id", "createdAt", "updatedAt", "rawTranscription", "postProcessedText", "model",
            "duration", "wordCount", "originPlatform"
        ]))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for localValue in ["synthetic-local", "Private response", "Private local error", "Private metadata"] {
            XCTAssertFalse(text.contains(localValue))
        }
    }
}
