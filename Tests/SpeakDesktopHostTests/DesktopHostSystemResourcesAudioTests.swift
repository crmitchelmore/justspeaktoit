import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

/// Audio output in "System resources in use" (#1473): History playback is a
/// releasable hold, and a voice export is not mistaken for speech playback.
extension DesktopHostReadAloudTests {
    func testHistoryPlayback_IsListedAndStoppedFromStatus() async throws {
        let registry = SystemResourceRegistry()
        await controller.useSystemResourceRegistry(registry)
        await controller.playbackToggle(record.uuidString)
        let hold = try XCTUnwrap(registry.holds.first { $0.title == "Recording playback" })
        XCTAssertEqual(hold.kind, .audioOutput)
        XCTAssertEqual(hold.releaseTitle, "Stop playback")
        let released = await DesktopSystemResources.release(hold.id.uuidString, registry: registry)
        XCTAssertTrue(released)
        let playing = await controller.playback.isPlayingSavedAudio
        XCTAssertFalse(playing)
        XCTAssertTrue(registry.holds.isEmpty, "Stopping the player ends its hold")
    }

    func testHistoryPlayback_HoldEndsWhenThePlayerFinishesOnItsOwn() async throws {
        let registry = SystemResourceRegistry()
        await controller.useSystemResourceRegistry(registry)
        await controller.playbackToggle(record.uuidString)
        XCTAssertEqual(registry.holds.map(\.title), ["Recording playback"])
        await controller.playback.finishSavedAudio()
        try await waitFor("the playback hold to end") { registry.holds.isEmpty }
    }

    func testVoiceExport_IsABackgroundTaskNotSpeechPlayback() async throws {
        let registry = SystemResourceRegistry()
        await controller.useSystemResourceRegistry(registry)
        let export = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        await controller.setVoiceExportTaskForTest(export)
        let hold = try XCTUnwrap(registry.holds.first)
        XCTAssertEqual(registry.holds.count, 1)
        XCTAssertEqual(hold.kind, .backgroundTask)
        XCTAssertEqual(hold.title, "Voice export")
        XCTAssertEqual(hold.releaseTitle, "Cancel export")
        let released = await DesktopSystemResources.release(hold.id.uuidString, registry: registry)
        XCTAssertTrue(released)
        XCTAssertTrue(export.isCancelled)
        XCTAssertTrue(registry.holds.isEmpty)
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func setVoiceExportTaskForTest(_ task: Task<Void, Never>) { readAloudState.exportTask = task }
}
