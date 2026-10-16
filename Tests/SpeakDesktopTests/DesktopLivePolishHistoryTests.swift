import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLivePolishHistoryTests: XCTestCase {
    func testNativeAndPortableHistory_RoundTripRawAndSuccessfulPolishWithoutRerunningClient() async throws {
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish), modelIdentifier: ModelCatalog.defaultFastTextModel,
            complete: { _ in "Clean." }
        )
        let outcome = await session.finish("raw")
        var record = DesktopRecordingStore.Record(
            id: session.recordingID, audioFilename: "fixture.wav",
            modelIdentifier: AssemblyAIModels.universal36ProStreamingID
        )
        record.result = .init(
            text: "raw", segments: [], confidence: nil, duration: 1, modelIdentifier: record.modelIdentifier,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.processedText = outcome.text
        record.livePolishResult = outcome
        record.postProcessingModelIdentifier = outcome.modelIdentifier
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DesktopRecordingStore.Record.self, from: encoded)
        XCTAssertEqual(decoded.originalText, "raw")
        XCTAssertEqual(decoded.displayText, "Clean.")
        XCTAssertEqual(decoded.livePolishResult, outcome)
        let value = try DesktopMigrationHistory.value(decoded)
        let imported = DataMigrationRecord(
            id: record.id.uuidString, kind: "history", value: value, date: record.createdAt
        )
        let restored = try DesktopMigrationHistory.record(imported, category: .history)
        XCTAssertEqual(restored.originalText, "raw")
        XCTAssertEqual(restored.processedText, "Clean.")
        XCTAssertEqual(restored.livePolishResult, outcome)
        XCTAssertEqual(try DesktopMigrationHistory.value(restored), value)
    }
}
