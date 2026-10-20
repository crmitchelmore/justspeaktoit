import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

final class DataMigrationHistorySchemaTests: XCTestCase {
    private let id = "12345678-1234-1234-1234-123456789ABC"
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    private func legacyValue() throws -> AnyCodable {
        let json = """
        {
          "id": "\(id)", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:01Z",
          "modelsUsed": ["apple/local/SFSpeechRecognizer"], "modelUsages": [],
          "rawTranscription": "Original text", "recordingDuration": 1.25,
          "networkExchanges": [], "events": [], "phaseTimestamps": {},
          "trigger": {"gesture": "automation", "hotKeyDescription": "Shortcut", "outputMethod": "clipboard"},
          "errors": []
        }
        """
        return try DataMigrationCoding.decoder.decode(AnyCodable.self, from: Data(json.utf8))
    }

    private func record(kind: String = "history") throws -> DataMigrationRecord {
        .init(id: id, kind: kind, value: try legacyValue(), date: date)
    }

    private func snapshot(
        _ records: [DataMigrationRecord], category: DataMigrationCategory = .history,
        scope: DataMigrationScope = .init()
    ) -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [category], scopes: [category.rawValue: scope]),
              records: [category: records])
    }

    private func validate(_ snapshot: DataMigrationSnapshot) -> DataMigrationSnapshot {
        DataMigrationRecordValidation.validate(snapshot) { record, category in
            _ = try DataMigrationHistorySchema.validate(record, category: category)
        }
    }

    func testLegacyHistory_UsesExactRequiredAndOptionalMacWireFields() throws {
        let item = try DataMigrationHistorySchema.validate(record(), category: .history)
        XCTAssertEqual(item.id.uuidString, id)
        XCTAssertEqual(item.createdAt, date)
        XCTAssertEqual(item.rawTranscription, "Original text")
        XCTAssertEqual(item.recordingDuration, 1.25)
        XCTAssertEqual(item.modelsUsed, ["apple/local/SFSpeechRecognizer"])
        XCTAssertEqual(item.modelUsages, [])
        XCTAssertEqual(item.trigger.gesture, .automation)
        XCTAssertNil(item.source)
        XCTAssertNil(item.latency)
        XCTAssertNil(item.diagnosticContext)
        XCTAssertNil(item.postProcessingPrompt)
        XCTAssertNil(item.personalCorrections)
        XCTAssertNil(item.audioFileURL)
        XCTAssertNil(item.postProcessedTranscription)
        XCTAssertEqual(try DataMigrationCoding.value(item), try legacyValue())
    }

    func testRequiredArraysAndUnknownEnumValues_RemainStrict() throws {
        for key in ["modelsUsed", "modelUsages", "networkExchanges", "events", "errors"] {
            var object = try XCTUnwrap(legacyValue().value as? [String: Any])
            object.removeValue(forKey: key)
            var invalid = try record()
            invalid.value = try AnyCodable(object)
            XCTAssertThrowsError(try DataMigrationHistorySchema.validate(invalid, category: .history), key)
        }
        var invalid = try record()
        var object = try XCTUnwrap(legacyValue().value as? [String: Any])
        object["trigger"] = ["gesture": "unknown", "hotKeyDescription": "Shortcut", "outputMethod": "clipboard"]
        invalid.value = try AnyCodable(object)
        XCTAssertThrowsError(try DataMigrationHistorySchema.validate(invalid, category: .history))
    }

    func testMemberwiseOptionalDefaults_RemainSourceCompatible() {
        let timestamps = ApplicationPhaseTimestamps()
        XCTAssertNil(timestamps.recordingStarted)
        XCTAssertNil(timestamps.outputDelivered)
        XCTAssertNil(ApplicationHistoryCost(total: 0, currency: "USD").breakdown)
        XCTAssertNil(ApplicationHistoryTrigger(gesture: .uiButton, hotKeyDescription: "", outputMethod: .none)
            .destinationApplication)
        XCTAssertNil(ApplicationPostProcessingPromptPayload(modelIdentifier: "model", systemPrompt: "", userPrompt: "")
            .customPrompt)
    }

    func testMetadata_RoundTripsAllFieldsWithOriginalJSONNames() throws {
        let item = ApplicationHistoryItem(
            id: UUID(uuidString: id)!, createdAt: date, updatedAt: date,
            modelsUsed: ["model"], modelUsages: [.init(modelIdentifier: "model", phase: .postProcessing)],
            rawTranscription: "Raw", postProcessedTranscription: "Processed", recordingDuration: 2,
            cost: .init(total: 0.25, currency: "USD",
                        breakdown: .init(inputTokens: 3, outputTokens: 4, totalCost: 0.25, currency: "USD")),
            audioFileURL: URL(fileURLWithPath: "/synthetic/recording.wav"),
            networkExchanges: [.init(url: URL(string: "https://example.invalid/transcription")!, method: "POST",
                                     requestHeaders: [:], requestBodyPreview: "request", responseCode: 200,
                                     responseHeaders: [:], responseBodyPreview: "response")],
            events: [.init(kind: .outputDelivered, timestamp: date, description: "Delivered")],
            phaseTimestamps: .init(recordingStarted: date, recordingEnded: date.addingTimeInterval(2),
                                   transcriptionStarted: date, transcriptionEnded: date.addingTimeInterval(1),
                                   postProcessingStarted: date, postProcessingEnded: date.addingTimeInterval(3),
                                   outputDelivered: date),
            trigger: .init(gesture: .hold, hotKeyDescription: "Fn", outputMethod: .accessibility,
                           destinationApplication: "Synthetic editor"),
            personalCorrections: .init(
                applied: [.init(ruleID: UUID(), alias: "alias", canonical: "canonical", occurrences: 1,
                                wasApplied: true, confidence: .high, reason: nil)],
                suggestions: [], contextTags: ["context"], destinationApplication: "Synthetic editor"
            ),
            errors: [.init(phase: .storage, message: "Synthetic", debugDescription: "Detail", occurredAt: date)],
            source: .importedFile,
            postProcessingPrompt: .init(modelIdentifier: "model", customPrompt: "Custom",
                                        systemPrompt: "System", userPrompt: "User"),
            diagnosticContext: .init(capturedAt: date, appVersion: "1", appBuild: "2", operatingSystem: "Synthetic",
                                     processIdentifier: 3, microphonePermission: "Granted", inputDeviceName: "Input",
                                     providerLabel: "Provider", latencyTier: "Fast", transcriptionMode: "Batch",
                                     transcriptionModel: "model", postProcessingModel: "model", speedMode: "Fast"),
            latency: .init(captureStartMs: 12, firstPartialMs: 13, firstInsertMs: 14, stopToFinalMs: 15)
        )
        let value = try DataMigrationCoding.value(item)
        let decoded = try DataMigrationCoding.decode(ApplicationHistoryItem.self, value)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.phaseTimestamps.transcriptionDurationMs, 1000)
        XCTAssertEqual(decoded.phaseTimestamps.postProcessingDurationMs, 3000)
        let keys = try XCTUnwrap(value.value as? [String: Any]).keys
        XCTAssertEqual(Set(keys), Set([
            "id", "createdAt", "updatedAt", "modelsUsed", "modelUsages", "rawTranscription",
            "postProcessedTranscription", "recordingDuration", "cost", "audioFileURL", "networkExchanges",
            "events", "phaseTimestamps", "trigger", "personalCorrections", "errors", "source",
            "postProcessingPrompt", "diagnosticContext", "latency"
        ]))
        func requiresSendable<T: Sendable>(_: T) {}
        requiresSendable(decoded)
    }

    func testHistoryIdentityDateDurationAndCategory_RejectMismatch() throws {
        for variant in 0..<6 {
            var invalid = try record()
            var category = DataMigrationCategory.history
            if variant == 0 { invalid.id = "not-a-uuid" }
            if variant == 1 { invalid.id = UUID().uuidString }
            if variant == 2 { invalid.date = nil }
            if variant == 3 { invalid.date = date.addingTimeInterval(1) }
            if variant == 4 {
                var object = try XCTUnwrap(legacyValue().value as? [String: Any])
                object["recordingDuration"] = -1
                invalid.value = try AnyCodable(object)
            }
            if variant == 5 { category = .recordings }
            XCTAssertThrowsError(try DataMigrationHistorySchema.validate(invalid, category: category), "\(variant)")
        }
        var lowercase = try record()
        lowercase.id = id.lowercased()
        XCTAssertNoThrow(try DataMigrationHistorySchema.validate(lowercase, category: .history))
        XCTAssertNoThrow(try DataMigrationHistorySchema.validate(record(kind: "audio"), category: .recordings))
        XCTAssertThrowsError(try DataMigrationHistorySchema.validate(record(kind: "other"), category: .history))
    }

    func testExportedScopes_UseInclusiveStartExclusiveEndAndSelectedIdentifiers() throws {
        let valid = try record()
        for scope in [
            DataMigrationScope(start: date.addingTimeInterval(1)),
            DataMigrationScope(end: date),
            DataMigrationScope(selectedIDs: []),
            DataMigrationScope(selectedIDs: [UUID().uuidString])
        ] {
            let result = validate(snapshot([valid], scope: scope))
            XCTAssertEqual(result.records[.history], [])
            XCTAssertEqual(result.notices, ["History text & speech usage, \(id): skipped invalid or unsupported item."])
        }
        let scope = DataMigrationScope(start: date, end: date.addingTimeInterval(1), selectedIDs: [id])
        XCTAssertEqual(validate(snapshot([valid], scope: scope)).records[.history], [valid])
        let audio = try record(kind: "audio")
        XCTAssertEqual(validate(snapshot([audio], category: .recordings, scope: .init(end: date)))
            .records[.recordings], [])
    }

    func testMissingAndInvalidCategories_PreserveCurrentRecordsOnReplacement() throws {
        let valid = try record()
        let current = snapshot([valid])
        var missing = current
        missing.records = [:]
        XCTAssertNil(validate(missing).records[.history])
        var invalid = valid
        invalid.value = AnyCodable(.string("Not a History item"))
        let incoming = validate(snapshot([invalid]))
        let result = try DataMigrationPlanner.plan(
            current: current, incoming: incoming, modes: [.history: .replace], useImported: [],
            digest: MigrationPlannerFixtures.digest
        )
        XCTAssertEqual(result.records[.history], [valid])
        XCTAssertTrue(result.notices.contains { $0.hasPrefix(DataMigrationCategory.history.title + ",") })
        XCTAssertEqual(validate(snapshot([])).records[.history], [])
    }

    func testValidator_IsMandatoryAndItsCategoryFailureIsReportedWithoutMutatingFiles() throws {
        let valid = try record()
        let file = URL(fileURLWithPath: "/synthetic/staged.wav")
        var incoming = snapshot([valid])
        incoming.files = ["recordings/audio.wav": file]
        incoming.notices = ["Existing notice"]
        var calls: [String] = []
        let result = DataMigrationRecordValidation.validate(incoming) { record, category in
            calls.append(category.rawValue + ":" + record.identity)
            throw DataMigrationError.invalid("Synthetic unsupported category")
        }
        XCTAssertEqual(calls, ["history:history:" + id])
        XCTAssertEqual(result.records[.history], [])
        XCTAssertEqual(result.files, incoming.files)
        XCTAssertEqual(result.notices.first, "Existing notice")
        XCTAssertEqual(incoming.records[.history], [valid])
    }
}
