import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostHistoryDeletionTests: XCTestCase {
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
            id: deleted.id, revision: UUID(), audioFilename: "original.wav",
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
