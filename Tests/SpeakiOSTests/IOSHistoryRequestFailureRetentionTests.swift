#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSHistoryRequestFailureRetentionTests: XCTestCase {
    func testExistingNilCodecsStayExactAndOnlyRecordedFailureAddsAKey() throws {
        let plain = IOSRequestFailureValues.item(context: nil, failure: nil)
        let old = iOSHistoryItem(id: plain.id, createdAt: plain.createdAt, transcription: plain.transcription,
                                 postProcessedTranscription: plain.postProcessedTranscription,
                                 model: plain.model, duration: plain.duration, wordCount: plain.wordCount)
        XCTAssertEqual(try IOSRequestFailureValues.encode(old), try IOSRequestFailureValues.encode(plain))
        XCTAssertEqual(try IOSRequestFailureValues.object(IOSRequestFailureValues.encode(plain)).count, 9)
        // Optional pre-existing native fields are omitted when absent.
        let admitted = IOSRequestFailureValues.item(failure: nil)
        XCTAssertNil(try IOSRequestFailureValues.object(IOSRequestFailureValues.encode(admitted))["requestFailure"])
        let failed = IOSRequestFailureValues.item()
        let object = try IOSRequestFailureValues.object(IOSRequestFailureValues.encode(failed))
        XCTAssertNotNil(object["requestContext"])
        XCTAssertNotNil(object["requestFailure"])
        XCTAssertNil(failed.errorMessage, "A typed original failure does not manufacture a legacy error string")
        XCTAssertNil(failed.requestContext?.observedProvider)
    }

    func testNewOptionalFailureIsLossyButOldNativeFieldsRemainStrict() throws {
        let original = IOSRequestFailureValues.item(failure: nil)
        let encoded = try IOSRequestFailureValues.encode(original)
        var object = try IOSRequestFailureValues.object(encoded)
        for invalid: Any in ["private failure", 7, ["code": "future"], NSNull()] {
            object["requestFailure"] = invalid
            let decoded = try JSONDecoder().decode(iOSHistoryItem.self,
                                                    from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.requestFailure)
            XCTAssertEqual(decoded.requestContext, original.requestContext)
            XCTAssertEqual(try IOSRequestFailureValues.encode(decoded), encoded)
        }
        object["duration"] = "invalid old field"
        XCTAssertThrowsError(try JSONDecoder().decode(iOSHistoryItem.self,
                                                     from: JSONSerialization.data(withJSONObject: object)))
    }

    func testNativeRecordAndTextErrorCopiesKeepOriginalFailureAndRichMemoryMetadata() throws {
        let original = IOSRequestFailureValues.item()
        let rich = HistoryRecord(
            id: original.id, createdAt: original.createdAt, updatedAt: original.updatedAt,
            rawTranscription: original.transcription, postProcessedTranscription: original.postProcessedTranscription,
            recordingDuration: original.duration,
            cost: .init(total: 1, currency: "USD"),
            desktopHistory: .init(.object(["privateSyntheticMetadata": .string("owned")])),
            model: original.model, wordCount: original.wordCount, originPlatform: original.originPlatform,
            requestContext: original.requestContext, requestFailure: original.requestFailure
        )
        let decodedRecord = try JSONDecoder().decode(HistoryRecord.self, from: IOSRequestFailureValues.encode(rich))
        let adapted = iOSHistoryItem(historyRecord: decodedRecord)
        XCTAssertEqual(adapted.historyRecord, rich)
        let copied = adapted.withPostProcessed("successful later polish", updatedAt: rich.updatedAt)
            .withError("private later post-processing failure")
        XCTAssertEqual(copied.requestFailure, original.requestFailure)
        XCTAssertEqual(copied.requestContext, original.requestContext)
        XCTAssertEqual(copied.historyRecord.cost, rich.cost)
        XCTAssertEqual(copied.historyRecord.desktopHistory, rich.desktopHistory)
        XCTAssertEqual(copied.withError(nil).requestFailure, original.requestFailure)
        let persisted = try JSONDecoder().decode(iOSHistoryItem.self, from: IOSRequestFailureValues.encode(adapted))
        XCTAssertEqual(persisted.historyRecord, original.historyRecord)
        XCTAssertNil(persisted.historyRecord.cost)
        XCTAssertNil(persisted.historyRecord.desktopHistory)
    }

    func testActualWorkerFailureOnlyRevisionAndRecoveryRetainOutcomeAcrossRestart() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let worker = fixture.worker()
        let original = IOSRequestFailureValues.item(failure: nil)
        let first = await worker.result(for: worker.admit(.upsert(original), revision: 1))
        var object = try IOSRequestFailureValues.object(IOSRequestFailureValues.encode(original))
        object["requestFailure"] = try JSONSerialization.jsonObject(with: IOSRequestFailureValues.encode(
            IOSRequestFailureValues.failure
        ))
        let changed = try JSONDecoder().decode(iOSHistoryItem.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        fixture.storage.failPrimaryWrites = true
        let second = await worker.result(for: worker.admit(.upsert(changed), revision: 2))
        XCTAssertEqual(first.versions[original.id], 1)
        XCTAssertEqual(second.versions[original.id], 2)
        XCTAssertEqual(second.durableVersions[original.id], 2)
        XCTAssertTrue(second.durable)
        XCTAssertEqual(changed.updatedAt, original.updatedAt)
        XCTAssertNil(try fixture.read().first?.requestFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.appendingPathExtension("recovery").path))
        fixture.storage.failPrimaryWrites = false
        let restarted = fixture.worker()
        let loaded = await restarted.result(for: restarted.admit(.load, revision: 3))
        XCTAssertTrue(loaded.isReady)
        XCTAssertEqual(loaded.rows.first?.requestFailure, IOSRequestFailureValues.failure)
        XCTAssertEqual(try fixture.read().first?.requestFailure, IOSRequestFailureValues.failure)
        XCTAssertEqual(try fixture.read().first?.requestContext, original.requestContext)
    }

    func testSyncNineFieldsExcludeFailureAndNewerRemoteNeverInheritsIt() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let worker = fixture.worker()
        let original = IOSRequestFailureValues.item()
        _ = await worker.result(for: worker.admit(.upsert(original), revision: 1))
        let sync = original.toSyncable()
        let keys = Set(try IOSRequestFailureValues.object(IOSRequestFailureValues.encode(sync)).keys)
        XCTAssertEqual(keys, Set(["id", "createdAt", "rawTranscription", "postProcessedText", "model",
                                  "duration", "wordCount", "originPlatform", "updatedAt"]))
        for offset in [-1.0, 0, 1] {
            let remote = iOSHistoryItem.fromSyncable(.init(
                id: sync.id, createdAt: sync.createdAt, rawTranscription: sync.rawTranscription,
                postProcessedText: sync.postProcessedText, model: sync.model, duration: sync.duration,
                wordCount: sync.wordCount, originPlatform: "remote",
                updatedAt: sync.updatedAt.addingTimeInterval(offset)
            ))
            XCTAssertNil(remote.requestFailure)
            let result = await worker.result(for: worker.admit(.remote(remote), revision: UInt64(offset + 3)))
            XCTAssertEqual(result.rows.first?.requestFailure, offset > 0 ? nil : original.requestFailure)
            XCTAssertEqual(result.rows.first?.requestContext, offset > 0 ? nil : original.requestContext)
        }
    }

    func testActualReportKeepsTypedFailureWithNilErrorAndPreservesOverlappingLegacyFact() throws {
        let canary = "PRIVATE_FAILURE_user@example.com/path?key=secret"
        let original = IOSRequestFailureValues.item()
        let snapshot = IOSIssueReporter.snapshot(for: original)
        let json = try IOSRequestFailureValues.object(snapshot.full.jsonData)
        let failures = try XCTUnwrap(json["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?["stage"] as? String, "finalization")
        XCTAssertEqual(failures.first?["code"] as? String, "timeout")
        XCTAssertEqual(failures.first?["domain"] as? String, "application")
        let mixed = IOSIssueReporter.snapshot(for: original.withError(canary))
        let mixedJSON = try IOSRequestFailureValues.object(mixed.full.jsonData)
        let observations = try XCTUnwrap(mixedJSON["failures"] as? [[String: Any]])
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.last?["code"] as? String, "unknown")
        XCTAssertEqual(observations.last?["domain"] as? String, "unknown")
        for value in [mixed.full, mixed.withoutDetails] {
            XCTAssertFalse((value.body + value.jsonString + (value.issueURL?.absoluteString ?? "")).contains(canary))
        }
        let removed = try IOSRequestFailureValues.object(mixed.withoutDetails.jsonData)
        XCTAssertNil(removed["context"])
        XCTAssertNil(removed["failures"])
        XCTAssertNil(mixedJSON["observedHandoff"])
        XCTAssertNil(mixedJSON["postProcessingHandoff"])
    }
}

@MainActor
enum IOSRequestFailureValues {
    static let failure = RequestDiagnosticContext.Failure(stage: .finalization, code: .timeout, domain: .application)
    static let context = RequestDiagnosticContext(
        model: .project("deepgram/nova-3-streaming"), mode: .live
    )

    static func item() -> iOSHistoryItem { self.item(context: self.context, failure: self.failure) }

    static func item(failure: RequestDiagnosticContext.Failure?) -> iOSHistoryItem {
        self.item(context: self.context, failure: failure)
    }

    static func item(
        context: RequestDiagnosticContext?, failure: RequestDiagnosticContext.Failure?
    ) -> iOSHistoryItem {
        iOSHistoryItem(createdAt: Date(timeIntervalSince1970: 1_700_000_000), transcription: "retained partial",
                       postProcessedTranscription: "owned polish", model: "deepgram/nova-3-streaming",
                       duration: 1, wordCount: 2,
                       requestContext: context, requestFailure: failure)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
#endif
