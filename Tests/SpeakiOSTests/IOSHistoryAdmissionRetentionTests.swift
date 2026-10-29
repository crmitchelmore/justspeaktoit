#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSHistoryAdmissionRetentionTests: XCTestCase {
    func testLegacyTenKeysAndNilEncodingRemainExactWithEleventhKeyOnlyWhenRecorded() throws {
        let explicitNil = self.item(context: nil)
        let old = iOSHistoryItem(
            id: explicitNil.id, createdAt: explicitNil.createdAt, updatedAt: explicitNil.updatedAt,
            transcription: explicitNil.transcription,
            postProcessedTranscription: explicitNil.postProcessedTranscription,
            model: explicitNil.model, duration: explicitNil.duration, wordCount: explicitNil.wordCount,
            originPlatform: explicitNil.originPlatform, errorMessage: explicitNil.errorMessage
        )
        XCTAssertEqual(try self.encoder().encode(old), try self.encoder().encode(explicitNil))
        let encoded = try self.encoder().encode(old)
        let object = try self.object(encoded)
        XCTAssertEqual(Set(object.keys), Set(["id", "createdAt", "updatedAt", "transcription",
            "postProcessedTranscription", "model", "duration", "wordCount", "originPlatform", "errorMessage"]))
        let decoded = try JSONDecoder().decode(iOSHistoryItem.self, from: encoded)
        XCTAssertNil(decoded.requestContext)
        XCTAssertEqual(try self.encoder().encode(decoded), encoded)
        let withContext = self.item(context: .init(mode: .batch))
        XCTAssertEqual(try self.object(self.encoder().encode(withContext)).count, 11)
    }

    func testNewOptionalFieldIsLossyAndOldRequiredNativeFieldsStayStrict() throws {
        let original = self.item(context: nil)
        let old = try self.encoder().encode(original)
        var object = try self.object(old)
        for invalid: Any in ["invalid", 7, ["mode": "future"], NSNull()] {
            object["requestContext"] = invalid
            let item = try JSONDecoder().decode(iOSHistoryItem.self,
                                                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(item.requestContext)
            XCTAssertEqual(try self.encoder().encode(item), old)
        }
        object["requestContext"] = "invalid"
        object["duration"] = "invalid old field"
        XCTAssertThrowsError(try JSONDecoder().decode(iOSHistoryItem.self,
                                                     from: JSONSerialization.data(withJSONObject: object)))
    }

    func testNativeCanonicalRoundTripAndBothCopiesRetainAdmission() throws {
        let context = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        let original = self.item(context: context)
        let record = try JSONDecoder().decode(HistoryRecord.self, from: self.encoder().encode(original.historyRecord))
        let restored = iOSHistoryItem(historyRecord: record)
        XCTAssertEqual(restored.requestContext, context)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.createdAt, original.createdAt)
        XCTAssertEqual(restored.transcription, original.transcription)
        XCTAssertEqual(restored.historyRecord, record)
        let edited = restored.withPostProcessed("new polish").withError("new private error")
        XCTAssertEqual(edited.requestContext, context)
        XCTAssertEqual(edited.historyRecord.requestContext, context)
        XCTAssertEqual(edited.historyRecord.diagnosticContext, record.diagnosticContext)
        let native = try JSONDecoder().decode(iOSHistoryItem.self, from: self.encoder().encode(restored))
        XCTAssertEqual(native.requestContext, context)
        XCTAssertEqual(native.historyRecord, original.historyRecord)
    }

    func testRichRecordMetadataIsRetainedInMemoryWhileNativeEncodingKeepsOnlyAdmission() throws {
        let context = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        let original = self.item(context: context)
        let rich = HistoryRecord(
            id: original.id, createdAt: original.createdAt, updatedAt: original.updatedAt,
            rawTranscription: original.transcription, postProcessedTranscription: original.postProcessedTranscription,
            recordingDuration: original.duration, cost: .init(total: 1, currency: "USD", breakdown: nil),
            diagnosticContext: self.syntheticLegacyDiagnostic(),
            desktopHistory: .init(.object(["syntheticPrivateMetadata": .string("owned fixture")])),
            model: original.model, wordCount: original.wordCount, originPlatform: original.originPlatform,
            errorMessage: original.errorMessage, requestContext: context
        )
        let adapted = iOSHistoryItem(historyRecord: rich)
        XCTAssertEqual(adapted.historyRecord, rich)
        XCTAssertEqual(adapted.requestContext, context)
        XCTAssertNotNil(adapted.historyRecord.diagnosticContext)
        XCTAssertNotNil(adapted.historyRecord.desktopHistory)
        XCTAssertNotNil(adapted.historyRecord.cost)
        let edited = adapted.withPostProcessed("edited", updatedAt: rich.updatedAt).withError("new private error")
        XCTAssertEqual(edited.historyRecord, rich.replacingLocalText(
            postProcessedTranscription: "edited", errorMessage: "new private error", updatedAt: rich.updatedAt
        ))
        XCTAssertEqual(edited.requestContext, context)
        let encoded = try self.encoder().encode(adapted)
        let object = try self.object(encoded)
        XCTAssertNotNil(object["requestContext"])
        for key in ["diagnosticContext", "desktopHistory", "cost"] { XCTAssertNil(object[key]) }
        let persisted = try JSONDecoder().decode(iOSHistoryItem.self, from: encoded)
        XCTAssertEqual(persisted.requestContext, context)
        XCTAssertEqual(persisted.historyRecord, original.historyRecord)
        XCTAssertNil(persisted.historyRecord.diagnosticContext)
        XCTAssertNil(persisted.historyRecord.desktopHistory)
        XCTAssertNil(persisted.historyRecord.cost)
    }

    func testSyncExcludesAdmissionAndActualWorkerRemoteTimestampPolicyKeepsOwnership() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let worker = fixture.worker()
        let original = self.item(context: .init(mode: .live))
        _ = await worker.result(for: worker.admit(.upsert(original), revision: 1))
        let sync = original.toSyncable()
        XCTAssertEqual(Set(try self.object(self.encoder().encode(sync)).keys), Set([
            "id", "createdAt", "rawTranscription", "postProcessedText", "model", "duration", "wordCount",
            "originPlatform", "updatedAt"
        ]))
        for offset in [-1.0, 0, 1] {
            let remote = iOSHistoryItem.fromSyncable(.init(
                id: sync.id, createdAt: sync.createdAt, rawTranscription: sync.rawTranscription,
                postProcessedText: sync.postProcessedText, model: sync.model, duration: sync.duration,
                wordCount: sync.wordCount, originPlatform: "remote",
                updatedAt: sync.updatedAt.addingTimeInterval(offset)
            ))
            XCTAssertNil(remote.requestContext)
            let receipt = await worker.result(for: worker.admit(.remote(remote), revision: UInt64(offset + 3)))
            XCTAssertEqual(receipt.rows.first?.requestContext, offset > 0 ? nil : original.requestContext)
        }
    }

    func testActualWorkerContextOnlyChangeReceivesNewVersionAndDurableReceipt() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let worker = fixture.worker()
        let original = self.item(context: nil)
        let first = await worker.result(for: worker.admit(.upsert(original), revision: 1))
        var object = try self.object(self.encoder().encode(original))
        object["requestContext"] = try JSONSerialization.jsonObject(with: self.encoder().encode(
            RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        ))
        let changed = try JSONDecoder().decode(iOSHistoryItem.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        let second = await worker.result(for: worker.admit(.upsert(changed), revision: 2))
        XCTAssertEqual(first.versions[original.id], 1)
        XCTAssertEqual(second.versions[original.id], 2)
        XCTAssertEqual(second.durableVersions[original.id], 2)
        XCTAssertEqual(changed.updatedAt, original.updatedAt)
        XCTAssertTrue(second.durable)
        XCTAssertEqual(try fixture.read().first?.requestContext, changed.requestContext)
    }

    func testContextOnlyRecoveryUsesActualDigestAndRetainsNewAdmissionOnRestart() async throws {
        let fixture = try IOSAdmissionFixture(self)
        let original = self.item(context: nil)
        let first = fixture.worker()
        _ = await first.result(for: first.admit(.upsert(original), revision: 1))
        fixture.storage.failPrimaryWrites = true
        var object = try self.object(self.encoder().encode(original))
        let context = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        object["requestContext"] = try JSONSerialization.jsonObject(with: self.encoder().encode(context))
        let changed = try JSONDecoder().decode(iOSHistoryItem.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        let recovery = await first.result(for: first.admit(.upsert(changed), revision: 2))
        XCTAssertTrue(recovery.durable, "Owned sidecar must be durable despite the held primary failure")
        XCTAssertNil(try fixture.read().first?.requestContext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.appendingPathExtension("recovery").path))
        fixture.storage.failPrimaryWrites = false
        let restarted = fixture.worker()
        let loaded = await restarted.result(for: restarted.admit(.load, revision: 3))
        XCTAssertEqual(loaded.rows.first?.requestContext, context)
        XCTAssertEqual(try fixture.read().first?.requestContext, context)
        XCTAssertTrue(loaded.isReady)
    }

    func testActualHistoryReportUsesOriginalAdmissionAndNeverRawLegacyValues() throws {
        let canary = "PRIVATE_IOS_REQUEST_user@example.com/path?token=secret"
        let context = RequestDiagnosticContext(model: .project("openai/whisper-1"), mode: .batch)
        let item = iOSHistoryItem(transcription: canary, model: canary, duration: 1, wordCount: 1,
                                  errorMessage: canary, requestContext: context)
        let frozen = IOSIssueReporter.snapshot(for: item)
        let json = try self.object(frozen.full.jsonData)
        let recorded = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual((recorded["model"] as? [String: Any])?["identifier"] as? String, "openai/whisper-1")
        XCTAssertNil(json["observedHandoff"])
        XCTAssertNil(json["postProcessingHandoff"])
        XCTAssertEqual((json["failures"] as? [[String: Any]])?.first?["code"] as? String, "unknown")
        XCTAssertFalse((frozen.full.jsonString + frozen.full.body + (frozen.full.issueURL?.absoluteString ?? ""))
            .contains(canary))
        XCTAssertNil(try self.object(frozen.withoutDetails.jsonData)["context"])
    }

    private func syntheticLegacyDiagnostic() -> ApplicationHistoryDiagnosticContext {
        .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "synthetic", appBuild: "synthetic",
              operatingSystem: "synthetic", processIdentifier: 123, microphonePermission: "synthetic",
              inputDeviceName: "private synthetic device", providerLabel: "private synthetic provider",
              latencyTier: "synthetic", transcriptionMode: "synthetic", transcriptionModel: "synthetic",
              postProcessingModel: "synthetic", speedMode: "synthetic")
    }

    private func item(context: RequestDiagnosticContext?) -> iOSHistoryItem {
        iOSHistoryItem(createdAt: Date(timeIntervalSince1970: 1_700_000_000), transcription: "owned",
                       postProcessedTranscription: "polished", model: "recorded", duration: 1, wordCount: 1,
                       errorMessage: "private local error", requestContext: context)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Fully owned files/defaults/IO; no shared manager, settings, sync engine,
/// secure storage, audio, provider or permission acquisition.
@MainActor
final class IOSAdmissionFixture {
    let directory: URL
    let file: URL
    let storage: HistoryAsyncStorage
    private let suite: String
    private let defaults: UserDefaults
    private var cancel: [() -> Void] = []
    private var exits: [XCTestExpectation] = []
    private var drains: [() async -> Void] = []

    init(_ test: XCTestCase) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.file = self.directory.appendingPathComponent("owned-history.json")
        self.suite = UUID().uuidString
        do {
            self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suite))
        } catch {
            try? FileManager.default.removeItem(at: self.directory)
            throw error
        }
        self.storage = HistoryAsyncStorage(primary: self.file)
        test.addTeardownBlock { @MainActor [self] in await self.cleanup() }
    }

    func worker() -> IOSHistoryPersistence {
        let worker = IOSHistoryPersistence(fileURL: self.file, storageIO: self.storage.storageIO)
        self.drains.append { _ = await worker.result(for: worker.admit(.load, revision: .max)) }
        return worker
    }

    func manager() -> iOSHistoryManager {
        let manager = iOSHistoryManager(
            fileURL: self.file, syncEnabled: false, userDefaults: self.defaults, storageIO: self.storage.storageIO,
            startSync: { _ in }, loadImmediately: false, uploadEntry: { _ in }, deleteEntry: { _ in },
            uploadSettled: { _ in }, removeNotificationClaims: { _ in }
        )
        self.drains.append { await manager.loadIfNeededAndWait() }
        return manager
    }

    func own<Success: Sendable>(_ task: Task<Success, Never>, exit: XCTestExpectation) {
        self.cancel.append { task.cancel() }
        self.exits.append(exit)
    }

    func read() throws -> [iOSHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([iOSHistoryItem].self, from: Data(contentsOf: self.file))
    }

    private func cleanup() async {
        self.cancel.forEach { $0() }
        self.storage.release()
        if !self.exits.isEmpty {
            guard await XCTWaiter.fulfillment(of: self.exits, timeout: 2) == .completed else {
                XCTFail("Owned History tasks did not exit; fixture retained")
                return
            }
        }
        for drain in self.drains {
            let done = XCTestExpectation(description: "Owned History queue quiesced")
            let task = Task { @MainActor in await drain(); done.fulfill() }
            guard await XCTWaiter.fulfillment(of: [done], timeout: 2) == .completed else {
                task.cancel()
                XCTFail("Owned History queue did not quiesce; fixture retained")
                return
            }
        }
        self.cancel.removeAll()
        self.drains.removeAll()
        self.defaults.removePersistentDomain(forName: self.suite)
        do { try FileManager.default.removeItem(at: self.directory) } catch {
            XCTFail("Owned History fixture cleanup failed")
        }
    }
}
#endif
