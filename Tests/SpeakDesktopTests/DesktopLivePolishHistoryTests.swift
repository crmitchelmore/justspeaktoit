import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLivePolishHistoryTests: XCTestCase {
    func testNativeAndPortableHistory_RoundTripRawAndSuccessfulPolishWithoutRerunningClient() async throws {
        let session = LivePolishSession(
            recordingID: UUID(), preferences: .init(mode: .livePolish),
            modelIdentifier: ModelCatalog.defaultFastTextModel,
            complete: { _ in "Clean." }
        )
        try markPhase("before_finish")
        let outcome = await session.finish("raw")
        try markPhase("after_finish")
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
        try markPhase("before_encode")
        let encoded = try JSONEncoder().encode(record)
        try markPhase("after_encode")
        try markPhase("before_decode")
        let decoded = try JSONDecoder().decode(DesktopRecordingStore.Record.self, from: encoded)
        try markPhase("after_decode")
        XCTAssertEqual(decoded.originalText, "raw")
        XCTAssertEqual(decoded.displayText, "Clean.")
        XCTAssertEqual(decoded.livePolishResult, outcome)
        try markPhase("before_to_portable")
        let value = try DesktopMigrationHistory.value(decoded)
        try markPhase("after_to_portable")
        let imported = DataMigrationRecord(
            id: record.id.uuidString, kind: "history", value: value, date: record.createdAt
        )
        try markPhase("before_to_native")
        let restored = try DesktopMigrationHistory.record(imported, category: .history)
        try markPhase("after_to_native")
        try markPhase("before_final_assertions")
        XCTAssertEqual(restored.originalText, "raw")
        XCTAssertEqual(restored.processedText, "Clean.")
        XCTAssertEqual(restored.livePolishResult, outcome)
        XCTAssertEqual(try DesktopMigrationHistory.value(restored), value)
        try markPhase("end")
    }

    private func markPhase(_ phase: StaticString) throws {
        let line = "JSTI_AUTOCLEAN_HISTORY_PHASE " + String(describing: phase) + "\n"
        try FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}
