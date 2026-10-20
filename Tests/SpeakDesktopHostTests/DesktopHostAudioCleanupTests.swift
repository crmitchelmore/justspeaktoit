import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostAudioCleanupTests: XCTestCase {
    func testRetryAfterAudioCleanup_PreservesSavedTranscriptAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-audio-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let id = UUID()
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: id.uuidString + ".wav",
            modelIdentifier: ModelCatalog.defaultBatchTranscriptionModel
        )
        record.result = TranscriptionResult(
            text: "Saved original.", segments: [], confidence: nil, duration: 1,
            modelIdentifier: record.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.processedText = "Saved processed."
        let folder = await controller.store.directory
        try Data([1]).write(to: folder.appendingPathComponent(record.audioFilename))
        try await controller.store.save(record)
        await controller.indexHistory(record)
        let metadata = folder.appendingPathComponent(id.uuidString + ".json")
        let before = try Data(contentsOf: metadata)
        await controller.beginAudioCleanupConfirmation()
        await finish(controller)
        let pending = await controller.audioCleanupConfirmation
        let token = try XCTUnwrap(pending?.id)
        await controller.answerAudioCleanup(token.uuidString, delete: true)
        await finish(controller)
        let refusal = await controller.retryRefusal(for: record.modelIdentifier)
        XCTAssertNil(refusal)
        await controller.retryHistory(id.uuidString)
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        let saved = try await controller.store.record(id: id)
        XCTAssertEqual(saved.result?.text, "Saved original.")
        XCTAssertEqual(saved.processedText, "Saved processed.")
        XCTAssertNil(saved.failure)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not retry recording:") == true)
        await controller.close()
    }

    func testHeldPlaybackStop_CloseIsBoundedAndLateCompletionCannotDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-audio-held-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(
            directory: root, effects: SyntheticEffects(), shutdownGrace: .milliseconds(20)
        )
        await controller.markReadyForSelfTest()
        let record = try await seed(controller)
        await controller.beginAudioCleanupConfirmation()
        await finish(controller)
        let pending = await controller.audioCleanupConfirmation
        let token = try XCTUnwrap(pending?.id)
        let gate = HeldAudioStop()
        FakeLog.shared.setSavedAudioStopper { await Task.detached { gate.hold() }.value }
        defer { gate.release(); FakeLog.shared.setSavedAudioStopper(nil) }
        await controller.answerAudioCleanup(token.uuidString, delete: true)
        let operation = await controller.audioCleanupTask
        await gate.waitUntilHeld()
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await operation?.value
        let folder = await controller.store.directory
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(record.audioFilename)), Data([1]))
        let remaining = await controller.activeOperations
        XCTAssertEqual(remaining, 0)
    }

    func testConfirmation_DeletesFrozenAudioAndKeepsHistoryAndLaterArrival() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let record = try await seed(controller)
        let folder = await controller.store.directory
        let metadata = folder.appendingPathComponent(record.id.uuidString + ".json")
        let before = try Data(contentsOf: metadata)
        await controller.beginAudioCleanupConfirmation()
        await finish(controller)
        let confirmation = await controller.audioCleanupConfirmation
        let token = try XCTUnwrap(confirmation?.id)
        let later = try await seed(controller)
        await controller.answerAudioCleanup(token.uuidString, delete: true)
        await finish(controller)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.audioFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(later.audioFilename).path))
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        let records = try await controller.store.records()
        XCTAssertEqual(Set(records.map(\.id)), [record.id, later.id])
        await controller.close()
    }

    func testCancelAndInvalidToken_CannotDeleteAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-audio-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let record = try await seed(controller)
        await controller.beginAudioCleanupConfirmation()
        await finish(controller)
        let pending = await controller.audioCleanupConfirmation
        let token = try XCTUnwrap(pending?.id)
        await controller.answerAudioCleanup(UUID().uuidString, delete: true)
        await controller.answerAudioCleanup(token.uuidString, delete: false)
        await controller.answerAudioCleanup(token.uuidString, delete: true)
        let folder = await controller.store.directory
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(record.audioFilename)), Data([1]))
        let current = await controller.audioCleanupConfirmation
        XCTAssertNil(current)
        await controller.close()
    }

    func testOperationStartedAfterConfirmation_RefusesCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-audio-busy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let record = try await seed(controller)
        await controller.beginAudioCleanupConfirmation()
        await finish(controller)
        let pending = await controller.audioCleanupConfirmation
        let token = try XCTUnwrap(pending?.id)
        await controller.setAudioBusyForTest(true)
        await controller.answerAudioCleanup(token.uuidString, delete: true)
        await controller.setAudioBusyForTest(false)
        let folder = await controller.store.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.audioFilename).path))
        await controller.close()
    }

    func testEmptyAndClosedController_DoNotPublishConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-audio-empty-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        await controller.beginAudioCleanupConfirmation()
        await finish(controller)
        let empty = await controller.audioCleanupConfirmation
        XCTAssertNil(empty)
        let record = try await seed(controller)
        await controller.close()
        await controller.beginAudioCleanupConfirmation()
        let closed = await controller.audioCleanupConfirmation
        XCTAssertNil(closed)
        let folder = await controller.store.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.audioFilename).path))
    }

    private func finish(_ controller: DesktopHostController<FakePlatform>) async {
        let operation = await controller.audioCleanupTask
        await operation?.value
    }

    private func seed(_ controller: DesktopHostController<FakePlatform>) async throws -> DesktopRecordingStore.Record {
        let id = UUID()
        let record = DesktopRecordingStore.Record(
            id: id, audioFilename: id.uuidString + ".wav", modelIdentifier: "test"
        )
        let folder = await controller.store.directory
        try Data([1]).write(to: folder.appendingPathComponent(record.audioFilename))
        try await controller.store.save(record)
        await controller.indexHistory(record)
        return record
    }
}

private extension DesktopHostController {
    func setAudioBusyForTest(_ value: Bool) { busy = value }
}

private final class HeldAudioStop: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func hold() { arrived.signal(); released.wait() }
    func waitUntilHeld() async { await Task.detached { self.arrived.wait() }.value }
    func release() { released.signal() }
}
