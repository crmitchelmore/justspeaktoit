import Foundation
import XCTest
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostRecordingLocationTests: XCTestCase {
    func testChoose_IsUnavailableWithoutQualifiedHeldCapture() async throws {
        #if os(Linux) && canImport(Glibc)
        throw XCTSkip("Linux has the qualified registry and held capture writer.")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("location-off-\(UUID())")
        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("location-off-audio-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: chosen)
        }
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.ready()
        await controller.chooseRecordingsDirectory(chosen.path)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains(DesktopHostRecordingLocation.unavailable))
        let selection = await controller.recordingLocation.selection
        XCTAssertNil(selection)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(DesktopHostRecordingLocation.filename).path
        ))
        await controller.close()
        #endif
    }

    func testUseDefault_KeepsHistoryAndMovesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("location-default-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.chooseRecordingsDirectory("   ")
        XCTAssertTrue(FakeLog.shared.allStatuses.contains("New recordings are saved in History."))
        let folder = await controller.recordingsFolderToReveal()
        let history = await controller.store.directory
        XCTAssertEqual(folder, history)
        await controller.close()
    }
}
