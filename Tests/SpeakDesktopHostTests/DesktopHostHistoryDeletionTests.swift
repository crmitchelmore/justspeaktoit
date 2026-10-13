import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostHistoryDeletionTests: XCTestCase {
    func testConfirmedSnapshot_DoesNotDeleteLaterArrivalsAndKeepsRequestedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-clear-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let first = try await seed(controller)
        let second = try await seed(controller)
        let frozen = [first.id, second.id].map(\.uuidString).joined(separator: "\n")
        let later = try await seed(controller)
        await controller.selectHistory(first.id.uuidString)
        await controller.deleteHistory(frozen, deleteAudio: false)
        let visible = await controller.history
        let selected = await controller.selectedHistoryID
        let text = await controller.transcript
        XCTAssertEqual(Set(visible.keys), [later.id])
        XCTAssertNil(selected)
        XCTAssertEqual(text, "")
        for recording in [first, second] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("History").appendingPathComponent(
                recording.audioFilename
            )), Data([1]))
        }
        await controller.close()
    }

    func testMalformedDuplicateAndBusyDeletion_DoNotRemoveHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let recording = try await seed(controller)
        for payload in ["", "not-an-id", recording.id.uuidString + "\n" + recording.id.uuidString] {
            await controller.deleteHistory(payload, deleteAudio: true)
        }
        await controller.setBusyForDeletionTest(true)
        await controller.deleteHistory(recording.id.uuidString, deleteAudio: true)
        await controller.setBusyForDeletionTest(false)
        let visible = await controller.history
        XCTAssertEqual(Set(visible.keys), [recording.id])
        let deleted = await controller.store.isDeleted(id: recording.id)
        XCTAssertFalse(deleted)
        await controller.close()
    }

    func testOwnershipFailure_RetainsTheRowAndReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-ownership-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let first = try await seed(controller)
        let other = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: first.audioFilename, modelIdentifier: "test"
        )
        try await controller.store.save(other)
        await controller.indexHistory(other)
        await controller.deleteHistory(first.id.uuidString, deleteAudio: true)
        let visible = await controller.history
        XCTAssertEqual(Set(visible.keys), [first.id, other.id])
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("deletion(s) need attention:") })
        await controller.close()
    }

    private func seed(
        _ controller: DesktopHostController<FakePlatform>
    ) async throws -> DesktopRecordingStore.Record {
        let id = UUID()
        var recording = DesktopRecordingStore.Record(
            id: id, audioFilename: id.uuidString + ".wav", modelIdentifier: "test"
        )
        recording.result = TranscriptionResult(
            text: "Synthetic retained transcript", segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
        )
        try await controller.store.save(recording)
        try Data([1]).write(to: controller.directory.appendingPathComponent("History").appendingPathComponent(
            recording.audioFilename
        ))
        await controller.indexHistory(recording)
        return recording
    }

    func testCancelDuringConfirmedClear_FinishesAdmittedDeletionAndKeepsRemainingRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let first = try await seed(controller)
        let second = try await seed(controller)
        let gate = HistoryDeletionGate()
        let store = controller.store
        await controller.installCloudSync(DesktopHostSyncHooks(deleteHistory: { id, deleteAudio in
            await gate.hold()
            try await store.delete(id: id, deleteAudio: deleteAudio)
        }))
        let deletion = Task {
            await controller.deleteHistory(
                [first.id, second.id].map(\.uuidString).joined(separator: "\n"), deleteAudio: true
            )
        }
        await gate.waitUntilHeld()
        await controller.cancelTranscription()
        await gate.release()
        await deletion.value
        let visible = await controller.history
        let busy = await controller.busy
        XCTAssertEqual(visible.count, 1)
        XCTAssertFalse(busy)
        let persisted = try await store.records()
        XCTAssertEqual(Set(persisted.map(\.id)), Set(visible.keys))
        await controller.close()
    }

    func testNativeAdmission_DrainsEventQueueAndBoundsShutdownDuringHeldDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-native-close-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(
            directory: root, effects: SyntheticEffects(), shutdownGrace: .milliseconds(20)
        )
        await controller.markReadyForSelfTest()
        let first = try await seed(controller)
        let second = try await seed(controller)
        let gate = HistoryDeletionGate()
        let store = controller.store
        await controller.installCloudSync(DesktopHostSyncHooks(deleteHistory: { id, deleteAudio in
            await gate.hold()
            try await store.delete(id: id, deleteAudio: deleteAudio)
        }))
        let queue = DesktopSettingsQueue()
        queue.submit {
            await controller.beginHistoryDeletion(
                [first.id, second.id].map(\.uuidString).joined(separator: "\n"), deleteAudio: false
            )
        }
        await gate.waitUntilHeld()
        let deletion = await controller.historyDeletionTask
        let drained = await DesktopHostShutdown.wait(within: .seconds(1)) { await queue.drain() }
        XCTAssertTrue(drained, "Native shutdown must not await the deletion inside its settings queue.")
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        XCTAssertTrue(deletion?.isCancelled == true)
        await gate.release()
        await deletion?.value
        let records = try await store.records()
        XCTAssertEqual(records.count, 1)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
        await queue.drain()
    }

    func testDeletion_CancelsOnlyAutomaticOutputOwnedByItsSnapshot() async throws {
        for deleteOutputOwner in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-output-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let effects = BlockingOutputEffects()
            defer { effects.release() }
            let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
            await controller.markReadyForSelfTest()
            let owner = try await seed(controller)
            let other = try await seed(controller)
            _ = await controller.beginOutput(
                "Synthetic output", output: DesktopHostRecordingOutput(options: FakeTextOutput(), target: "synthetic"),
                recordID: owner.id
            )
            let output = await controller.outputSlot.task
            let id = deleteOutputOwner ? owner.id : other.id
            await controller.deleteHistory(id.uuidString, deleteAudio: false)
            XCTAssertEqual(output?.isCancelled, deleteOutputOwner)
            effects.release()
            await output?.value
            await controller.close()
        }
    }

    func testStartupCleanupFailure_ReportsWarningAndRetainsUnaffectedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        let store = try DesktopRecordingStore(directory: directory)
        var retained = DesktopRecordingStore.Record(id: UUID(), audioFilename: "", modelIdentifier: "test")
        retained.result = TranscriptionResult(
            text: "Synthetic retained transcript", segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
        )
        try await store.save(retained)
        let deleted = DesktopRecordingStore.Record(id: UUID(), audioFilename: "changed.wav", modelIdentifier: "test")
        try await store.save(deleted)
        var ledger = DesktopHistoryDeletionLedger()
        ledger.intents[deleted.id] = .init(
            id: deleted.id, revision: UUID(), audioFilename: "original.wav", deleteAudio: nil,
            account: nil, localCleanupPending: true, cloudPending: false
        )
        try ledger.save(in: directory)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.ready()
        let visible = await controller.history
        XCTAssertEqual(Set(visible.keys), [retained.id])
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0.contains("History deletion cleanup needs attention:")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            deleted.id.uuidString + ".json"
        ).path))
        await controller.close()
    }

}

private extension DesktopHostController where Platform == FakePlatform {
    func setBusyForDeletionTest(_ value: Bool) { busy = value }
}

private actor HistoryDeletionGate {
    private var resumed: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation {
            resumed = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilHeld() async {
        if resumed != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        resumed?.resume()
        resumed = nil
    }
}
