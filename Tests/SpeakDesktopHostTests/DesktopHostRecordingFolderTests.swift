import Foundation
import XCTest
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostRecordingFolderTests: XCTestCase {
    func testReveal_UsesActualStorageDirectoryWithoutChangingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-reveal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let folder = await controller.store.directory
        let id = UUID()
        let record = DesktopRecordingStore.Record(
            id: id, audioFilename: id.uuidString + ".wav", modelIdentifier: "test"
        )
        try await controller.store.save(record)
        let audio = folder.appendingPathComponent(record.audioFilename)
        try Data([1, 2, 3]).write(to: audio)
        let metadata = folder.appendingPathComponent(id.uuidString + ".json")
        let originalMetadata = try Data(contentsOf: metadata)
        let before = try await controller.store.records()
        await controller.revealRecordingsDirectory()
        XCTAssertTrue(FakeLog.shared.revealedFolders.contains(folder))
        let after = try await controller.store.records()
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(try Data(contentsOf: metadata), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
        await controller.close()
    }

    func testMissingDirectory_ReportsFailureRatherThanOpeningAnAlternative() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let folder = await controller.store.directory
        try FileManager.default.removeItem(at: folder)
        await controller.revealRecordingsDirectory()
        XCTAssertFalse(FakeLog.shared.revealedFolders.contains(folder))
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.hasPrefix("Could not open the recordings folder:") })
        await controller.close()
    }

    func testClosedController_DoesNotLaunchFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-closed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let folder = await controller.store.directory
        await controller.close()
        await controller.revealRecordingsDirectory()
        XCTAssertFalse(FakeLog.shared.revealedFolders.contains(folder))
    }

    func testNativeLaunchFailure_IsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-launch-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let folder = await controller.store.directory
        FakeLog.shared.setDirectoryLauncher { url in
            if url == folder { throw DesktopHostError(message: "Synthetic file manager failure.") }
        }
        defer { FakeLog.shared.setDirectoryLauncher(nil) }
        await controller.revealRecordingsDirectory()
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0 == "Could not open the recordings folder: Synthetic file manager failure."
        })
        await controller.close()
    }

    func testHeldNativeLaunch_DeduplicatesAndDoesNotBlockClosing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-held-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(
            directory: root, effects: SyntheticEffects(), shutdownGrace: .milliseconds(20)
        )
        let folder = await controller.store.directory
        let gate = FolderLaunchGate()
        FakeLog.shared.setDirectoryLauncher { url in
            if url == folder { gate.hold() }
        }
        defer { gate.release(); FakeLog.shared.setDirectoryLauncher(nil) }
        let operation = Task { await controller.revealRecordingsDirectory() }
        await gate.waitUntilHeld()
        await controller.revealRecordingsDirectory()
        XCTAssertEqual(FakeLog.shared.revealedFolders.filter { $0 == folder }.count, 1)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await operation.value
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }
}

private final class FolderLaunchGate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func hold() { arrived.signal(); released.wait() }
    func waitUntilHeld() async { await Task.detached { self.arrived.wait() }.value }
    func release() { released.signal() }
}
