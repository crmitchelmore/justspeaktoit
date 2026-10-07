import Foundation
import SpeakCore
import XCTest

@testable import SpeakSync

/// Synthetic CloudKit Web Services JSON, with record fields produced by the
/// same field encoder the client sends, so reads and writes stay symmetric.
enum SyncWireFixture {
    static func fields(_ assignments: SyncRecordFieldAssignments) throws -> [String: Any] {
        var fields: [String: Any] = [:]
        for assignment in assignments where assignment.value != nil {
            let payload = try JSONEncoder().encode(CloudKitWebFieldPayload(value: assignment.value))
            fields[assignment.key] = try JSONSerialization.jsonObject(with: payload)
        }
        return fields
    }

    static func recordJSON(
        name: String,
        type: String?,
        tag: String? = "synthetic-tag",
        assignments: SyncRecordFieldAssignments
    ) throws -> [String: Any] {
        var object: [String: Any] = ["recordName": name, "fields": try fields(assignments)]
        if let type { object["recordType"] = type }
        if let tag { object["recordChangeTag"] = tag }
        return object
    }

    static func record(
        name: String,
        type: String?,
        tag: String? = "synthetic-tag",
        assignments: SyncRecordFieldAssignments
    ) throws -> CloudKitWebRecord {
        let object = try recordJSON(name: name, type: type, tag: tag, assignments: assignments)
        return try JSONDecoder().decode(CloudKitWebRecord.self, from: CloudKitWebFixture.data(object))
    }

    static func deletedJSON(name: String, type: String?) -> [String: Any] {
        var object: [String: Any] = ["recordName": name, "deleted": true]
        if let type { object["recordType"] = type }
        return object
    }

    static func historyJSON(_ entry: SyncableHistoryEntry, tag: String = "synthetic-tag") throws -> [String: Any] {
        try recordJSON(
            name: SyncSchema.History.recordName(for: entry.id),
            type: SyncSchema.History.recordType,
            tag: tag,
            assignments: HistoryRecordCodec.assignments(for: entry)
        )
    }

    static func comparisonJSON(
        _ revision: ModelComparisonRevision,
        tag: String = "synthetic-tag"
    ) throws -> [String: Any] {
        try recordJSON(
            name: SyncSchema.ComparisonRound.recordName(for: revision.id),
            type: SyncSchema.ComparisonRound.recordType,
            tag: tag,
            assignments: ComparisonRecordCodec.assignments(for: revision)
        )
    }

    static func zoneChanges(
        _ records: [[String: Any]],
        syncToken: String?,
        moreComing: Bool
    ) -> CloudKitWebServicesHTTPResponse {
        var zone: [String: Any] = [
            "zoneID": ["zoneName": SyncSchema.zoneName, "ownerRecordName": "_synthetic-owner"],
            "records": records,
            "moreComing": moreComing
        ]
        if let syncToken { zone["syncToken"] = syncToken }
        return CloudKitWebFixture.response(["zones": [zone]])
    }

    static func entry(
        id: UUID = UUID(),
        raw: String? = "synthetic transcript",
        processed: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_010.125)
    ) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.25),
            rawTranscription: raw,
            postProcessedText: processed,
            model: "openai/gpt-4o-transcribe",
            duration: 2.5,
            wordCount: 2,
            originPlatform: "windows",
            updatedAt: updatedAt
        )
    }

    static func round(updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ModelComparisonRound {
        let entries = ["a", "b"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "P", transcript: "text \($0)")
        }
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: updatedAt,
            inputMode: .streaming,
            sample: ModelComparisonSample(name: "Capture.wav", contentHash: "ff", durationSeconds: 3),
            language: "en",
            originPlatform: "macos",
            entries: entries,
            blindOrder: entries.map(\.id).reversed()
        )
    }
}

func assertSameEntry(
    _ actual: SyncableHistoryEntry?,
    _ expected: SyncableHistoryEntry,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actual else {
        XCTFail("Missing entry \(expected.id)", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.id, expected.id, file: file, line: line)
    XCTAssertEqual(actual.createdAt, expected.createdAt, file: file, line: line)
    XCTAssertEqual(actual.rawTranscription, expected.rawTranscription, file: file, line: line)
    XCTAssertEqual(actual.postProcessedText, expected.postProcessedText, file: file, line: line)
    XCTAssertEqual(actual.model, expected.model, file: file, line: line)
    XCTAssertEqual(actual.duration, expected.duration, file: file, line: line)
    XCTAssertEqual(actual.wordCount, expected.wordCount, file: file, line: line)
    XCTAssertEqual(actual.originPlatform, expected.originPlatform, file: file, line: line)
    XCTAssertEqual(actual.updatedAt, expected.updatedAt, file: file, line: line)
}
