import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// Shortcut inputs racing other work on the controller: each waits for its
/// text output, and a decision made before that wait never acts on a session
/// that changed during it.
final class DesktopHostShortcutRaceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        let model = DesktopHostModels.all[batchIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-key", name: credential)
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func records() async throws -> [DesktopRecordingStore.Record] {
        try await DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
            .recoverInterruptedRecordings().records
    }

    /// A shortcut waits for its text output while other work runs. One that
    /// saw no recording must not stop a recording started meanwhile.
    func testAStartHeldOnItsTextOutputNeverStopsARecordingStartedMeanwhile() async throws {
        let output = Gate(open: false)
        let stale = Task {
            await self.controller.shortcut(.init(
                input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
                target: "editor", targetExecutablePath: nil,
                textOutput: Task { await output.pass(); return FakeTextOutput() },
                modelIndex: self.batchIndex, deviceID: ""
            ))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        output.release()
        await stale.value
        let active = await controller.recording
        XCTAssertEqual(active?.trigger, .other, "the stale start left the other recording running")
    }

    /// One that saw a recording must not start another once it has ended.
    func testAStopHeldOnItsTextOutputNeverStartsARecording() async throws {
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let output = Gate(open: false)
        let stale = Task {
            await self.controller.shortcut(.init(
                input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
                target: "editor", targetExecutablePath: nil,
                textOutput: Task { await output.pass(); return FakeTextOutput() },
                modelIndex: self.batchIndex, deviceID: ""
            ))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        output.release()
        await stale.value
        let active = await controller.recording
        XCTAssertNil(active, "the stale stop started nothing")
        let saved = try await records()
        XCTAssertEqual(saved.count, 1)
    }
}
