import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationHistoryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    private func native() -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "original.wav", modelIdentifier: "openai/whisper-1", createdAt: date
        )
        record.result = TranscriptionResult(
            text: "Raw text", segments: [.init(startTime: 0, endTime: 1, text: "Raw text", isFinal: true)],
            confidence: 0.75, duration: 2, modelIdentifier: record.modelIdentifier,
            cost: .init(inputTokens: 3, outputTokens: 4, totalCost: 0.25, currency: "USD"),
            rawPayload: "Synthetic diagnostic payload",
            debugInfo: .init(endpoint: URL(string: "https://example.invalid")!,
                             requestHeaders: ["Authorization": "SYNTHETIC-NOT-A-CREDENTIAL"],
                             requestBodyPreview: "request", responseCode: 200,
                             responseHeaders: [:], responseBodyPreview: "response")
        )
        record.processedText = "Processed text"
        record.postProcessingModelIdentifier = "openrouter/model"
        record.languageIdentifier = "en"
        record.profileName = "Profile"
        record.profileNotes = ["Portable note"]
        record.postProcessingFailure = "Synthetic failure"
        return record
    }

    private func imported(_ value: AnyCodable, id: UUID, kind: String = "history") -> DataMigrationRecord {
        .init(id: id.uuidString, kind: kind, value: value, date: date)
    }

    func testNativeMetadata_RoundTripsWithoutDiagnosticsPathsOrRecursiveCarrier() throws {
        let original = native()
        let value = try DesktopMigrationHistory.value(original)
        let item = try DataMigrationCoding.decode(ApplicationHistoryItem.self, value)
        XCTAssertNil(item.audioFileURL)
        XCTAssertNil(item.diagnosticContext)
        XCTAssertTrue(item.networkExchanges.isEmpty)
        let retained = try JSONDecoder().decode(DesktopRecordingStore.Record.self,
                                               from: JSONEncoder().encode(XCTUnwrap(item.desktopHistory)))
        XCTAssertNil(retained.result?.rawPayload)
        XCTAssertNil(retained.result?.debugInfo)
        XCTAssertNil(retained.migrationMetadata)
        XCTAssertEqual(retained.audioFilename, "")
        XCTAssertEqual(item.errors.map(\.phase), [.postProcessing])
        let restored = try DesktopMigrationHistory.record(imported(value, id: original.id),
                                                          category: .history, audioFilename: "installed.wav")
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.audioFilename, "installed.wav")
        XCTAssertEqual(restored.originalText, original.originalText)
        XCTAssertEqual(restored.processedText, original.processedText)
        XCTAssertEqual(restored.result?.segments, original.result?.segments)
        XCTAssertEqual(restored.result?.confidence, original.result?.confidence)
        XCTAssertEqual(restored.result?.cost, original.result?.cost)
        XCTAssertEqual(restored.languageIdentifier, original.languageIdentifier)
        XCTAssertEqual(restored.profileName, original.profileName)
        XCTAssertEqual(restored.profileNotes, original.profileNotes)
        XCTAssertEqual(restored.postProcessingFailure, original.postProcessingFailure)
        XCTAssertEqual(try DesktopMigrationHistory.value(restored), value)
    }

    func testMacFieldsAndFutureMetadata_PersistAcrossNativeSaveAndExport() async throws {
        let original = native()
        var value = try DesktopMigrationHistory.value(original)
        guard case .object(var fields) = value.storage else { return XCTFail("Expected object") }
        fields.removeValue(forKey: "desktopHistory")
        fields["futureField"] = .object(["preserve": .bool(true)])
        fields["latency"] = .object(["firstInsertMs": .int(23)])
        fields["modelUsages"] = .array([
            .object(["modelIdentifier": .string("apple/local/SFSpeechRecognizer"), "phase": .string("live")]),
            .object(["modelIdentifier": .string("openai/whisper-1"), "phase": .string("batch")]),
            .object(["modelIdentifier": .string("openrouter/model"), "phase": .string("post-processing")])
        ])
        value = AnyCodable(.object(fields))
        let record = try DesktopMigrationHistory.record(imported(value, id: original.id), category: .history)
        XCTAssertFalse(record.isSyncedCopy)
        XCTAssertEqual(record.modelIdentifier, "apple/local/SFSpeechRecognizer")
        XCTAssertTrue(DesktopHistorySearch.modelIdentifiers(for: record).contains("openai/whisper-1"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopRecordingStore(directory: directory)
        try await store.save(record)
        let loaded = try await store.record(id: record.id)
        let exported = try DesktopMigrationHistory.value(loaded)
        guard case .object(let result) = exported.storage else { return XCTFail("Expected object") }
        XCTAssertEqual(result["futureField"], fields["futureField"])
        XCTAssertEqual(result["latency"], fields["latency"])
        XCTAssertEqual(result["modelUsages"], fields["modelUsages"])
        XCTAssertEqual(loaded.migrationMetadata, value)
        XCTAssertEqual(exported, value)
    }

    func testFractionalNativeTimestampAndUnknownCarrierFields_RemainStableAcrossRepeatedImports() throws {
        var original = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "private.wav", modelIdentifier: "openai/whisper-1",
            createdAt: date.addingTimeInterval(0.625)
        )
        original.recordedDuration = 2.5
        guard case .object(var fields) = try DesktopMigrationHistory.value(original).storage,
              case .object(var desktop) = fields["desktopHistory"] else { return XCTFail("Expected carrier") }
        desktop["futureNativeField"] = .object(["enabled": .bool(true)])
        fields["desktopHistory"] = .object(desktop)
        let value = AnyCodable(.object(fields))
        var restored = try DesktopMigrationHistory.record(imported(value, id: original.id), category: .history)
        XCTAssertEqual(restored.createdAt, original.createdAt)
        for _ in 0..<3 {
            let exported = try DesktopMigrationHistory.value(restored)
            XCTAssertEqual(exported, value)
            restored = try DesktopMigrationHistory.record(imported(exported, id: original.id), category: .history)
        }
    }

    func testCanonicalNilTranscriptsAndChangedScalarCost_DoNotReviveStaleNativeFields() throws {
        let original = native()
        guard case .object(var fields) = try DesktopMigrationHistory.value(original).storage else {
            return XCTFail("Expected object")
        }
        fields.removeValue(forKey: "rawTranscription")
        fields.removeValue(forKey: "postProcessedTranscription")
        fields["cost"] = .object(["total": .double(0.5), "currency": .string("USD")])
        let restored = try DesktopMigrationHistory.record(imported(AnyCodable(.object(fields)), id: original.id),
                                                          category: .history)
        XCTAssertNil(restored.result)
        XCTAssertNil(restored.processedText)
        XCTAssertEqual(restored.recordingCost?.total, 0.5)
        let item = try DataMigrationCoding.decode(ApplicationHistoryItem.self, DesktopMigrationHistory.value(restored))
        let carrier = try JSONDecoder().decode(DesktopRecordingStore.Record.self,
                                              from: JSONEncoder().encode(XCTUnwrap(item.desktopHistory)))
        XCTAssertNil(carrier.result)
        XCTAssertNil(carrier.processedText)
    }

    func testCanonicalCostOverridesStaleNativeTokenBreakdown() throws {
        let original = native()
        guard case .object(var fields) = try DesktopMigrationHistory.value(original).storage else {
            return XCTFail("Expected object")
        }
        fields["cost"] = .object(["total": .double(0.5), "currency": .string("USD")])
        let restored = try DesktopMigrationHistory.record(imported(AnyCodable(.object(fields)), id: original.id),
                                                          category: .history)
        XCTAssertNil(restored.result?.cost)
        XCTAssertEqual(restored.recordingCost?.total, 0.5)
    }

    func testNativeCodingKeysCoverStoredFields_AndCarrierHashIgnoresObjectOrder() throws {
        let record = native()
        XCTAssertEqual(Set(Mirror(reflecting: record).children.compactMap(\.label)),
                       Set(DesktopRecordingStore.Record.CodingKeys.allCases.map(\.rawValue)))
        let first = AnyCodable(.object(["first": .int(1), "second": .array([.bool(true)])]))
        let second = AnyCodable(.object(["second": .array([.bool(true)]), "first": .int(1)]))
        XCTAssertEqual(Set([first, second]).count, 1)
        let value = try DesktopMigrationHistory.value(record)
        let redecoded = try DataMigrationCoding.decoder.decode(AnyCodable.self,
                                                               from: DataMigrationCoding.encoder.encode(value))
        XCTAssertEqual(Set([value, redecoded]).count, 1)
    }

    func testAudioOnlyProjection_RemovesBothCanonicalAndEmbeddedTranscriptData() throws {
        let record = native()
        let value = try DesktopMigrationHistory.value(record, audioOnly: true)
        let item = try DataMigrationCoding.decode(ApplicationHistoryItem.self, value)
        XCTAssertNil(item.rawTranscription)
        XCTAssertNil(item.postProcessedTranscription)
        XCTAssertTrue(item.errors.isEmpty)
        let native = try JSONDecoder().decode(DesktopRecordingStore.Record.self,
                                              from: JSONEncoder().encode(XCTUnwrap(item.desktopHistory)))
        XCTAssertNil(native.result)
        XCTAssertNil(native.processedText)
        XCTAssertNil(native.failure)
        XCTAssertNil(native.postProcessingFailure)
        let restored = try DesktopMigrationHistory.record(imported(value, id: record.id, kind: "audio"),
                                                           category: .recordings, audioFilename: "installed.wav")
        XCTAssertEqual(restored.recordingDuration, 2)
        XCTAssertNil(restored.originalText)
        XCTAssertNil(restored.processedText)
        XCTAssertEqual(DesktopHistoryInsights(records: [restored]).recordingDuration, 2)
    }

    func testFlatMacCost_DoesNotInventTokensAndRemainsVisible() throws {
        let record = native()
        guard case .object(var fields) = try DesktopMigrationHistory.value(record).storage else {
            return XCTFail("Expected object")
        }
        fields.removeValue(forKey: "desktopHistory")
        fields["cost"] = .object(["total": .double(0.5), "currency": .string("USD")])
        let restored = try DesktopMigrationHistory.record(imported(AnyCodable(.object(fields)), id: record.id),
                                                          category: .history)
        XCTAssertNil(restored.result?.cost)
        XCTAssertEqual(restored.recordingCost?.total, 0.5)
        XCTAssertEqual(DesktopHistoryInsights(records: [restored]).spend, 0.5)
        XCTAssertNotNil(DesktopHistoryRowSummary(restored).cost)
    }

    func testCanonicalTextOverridesStaleNativeSegmentsAndConfidence() throws {
        let record = native()
        guard case .object(var fields) = try DesktopMigrationHistory.value(record).storage else {
            return XCTFail("Expected object")
        }
        fields["rawTranscription"] = .string("Edited on Mac")
        let restored = try DesktopMigrationHistory.record(imported(AnyCodable(.object(fields)), id: record.id),
                                                          category: .history)
        XCTAssertEqual(restored.originalText, "Edited on Mac")
        XCTAssertEqual(restored.result?.segments, [])
        XCTAssertNil(restored.result?.confidence)
    }

    func testUnsafeAudioNamesMalformedNativeMetadataAndWrongCategory_FailExplicitly() throws {
        let record = native()
        let value = try DesktopMigrationHistory.value(record)
        for name in ["../outside.wav", "folder/file.wav", "folder\\file.wav", "C:outside.wav", ".", "..", "bad\0.wav"] {
            XCTAssertThrowsError(try DesktopMigrationHistory.record(
                imported(value, id: record.id), category: .history, audioFilename: name
            ))
        }
        XCTAssertThrowsError(try DesktopMigrationHistory.record(imported(value, id: record.id), category: .recordings))
        guard case .object(var fields) = value.storage else { return XCTFail("Expected object") }
        fields["desktopHistory"] = .string("Invalid")
        XCTAssertThrowsError(try DesktopMigrationHistory.record(
            imported(AnyCodable(.object(fields)), id: record.id), category: .history
        ))
    }
}
