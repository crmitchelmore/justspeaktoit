import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostControllerTests: XCTestCase {
    private var directory: URL!
    private var effects: SyntheticEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = SyntheticEffects()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
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

    private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func testRecordingIsSavedBeforeTranscriptionAndOutputUsesTheStartSnapshot() async throws {
        await controller.toggle(
            target: "editor", modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput(label: "at-start")
        )
        let pending = try await records()
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.result, "the record must exist before any network request")
        effects.transcription.release()
        await controller.toggle(
            target: "other", modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput(label: "later")
        )
        try await waitFor("the automatic output") { !self.effects.outputs.isEmpty }
        let output = try XCTUnwrap(effects.outputs.first)
        XCTAssertEqual(output.0.label, "at-start")
        XCTAssertEqual(output.0.target, "editor")
        XCTAssertEqual(output.1, "Synthetic transcript")
        let saved = try await records()
        XCTAssertEqual(saved.first?.result?.text, "Synthetic transcript")
    }

    func testRecordingStartedWithoutATargetIsNotOutput() async throws {
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let saved = try await records()
        XCTAssertEqual(saved.first?.result?.text, "Synthetic transcript")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(effects.outputs.isEmpty)
    }

    func testMissingKeyRefusesToRecord() async throws {
        FakeLog.shared.reset()
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let saved = try await records()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(FakeLog.shared.allStatuses.isEmpty)
    }

    func testCancellingTranscriptionRetainsTheAudio() async throws {
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: GatedEffects(gate: Gate(open: false))
        )
        await controller.markReadyForSelfTest()
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let stopping = Task {
            await self.controller.toggle(
                target: nil, modelIndex: self.batchIndex, deviceID: "", targetExecutablePath: nil,
                textOutput: FakeTextOutput()
            )
        }
        try await waitFor("transcription to start") { FakeLog.shared.huds.last?.phase == .transcribing }
        await controller.cancelTranscription()
        await stopping.value
        let saved = try await records()
        let record = try XCTUnwrap(saved.first)
        XCTAssertEqual(record.failure, "Transcription cancelled. Audio retained.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename).path
        ))
    }

    func testClosingWhileRecordingKeepsTheAudio() async throws {
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await controller.close()
        let saved = try await records()
        let record = try XCTUnwrap(saved.first)
        XCTAssertEqual(record.failure, "Recording stopped when the app closed. Audio retained.")
    }

    func testCopyUsesTheSnapshotText() async throws {
        await controller.copyTranscript("Displayed text", variant: .original)
        XCTAssertEqual(FakeLog.shared.copies, ["Displayed text"])
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Original transcript copied.")
    }

    func testSavingAKeyNamesTheCredentialStore() async throws {
        await controller.saveKey("  new-key  ", modelIndex: batchIndex)
        let model = DesktopHostModels.all[batchIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        XCTAssertEqual(FakeLog.shared.key(credential), "new-key")
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "API key saved in the test keyring.")
    }

    func testUnqualifiedHostsOfferNoLiveModels() {
        XCTAssertTrue(DesktopHostModels.live.isEmpty)
        XCTAssertFalse(DesktopHostModels.all.contains { DesktopHostModels.isLive($0.id) })
    }

    private func shortcut(
        _ input: HotKeySessionPolicy.Input, style: HotKeyActivationStyle, at time: TimeInterval
    ) async {
        await controller.shortcut(.init(
            input: input, style: style, recognisedAt: time, target: "editor", targetExecutablePath: nil,
            textOutput: Task { FakeTextOutput() }, modelIndex: batchIndex, deviceID: ""
        ))
    }

    func testHoldStartsAndItsReleaseStops() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        await shortcut(.gesture(.holdStart), style: .holdAndDoubleTap, at: now)
        let recording = await controller.recording?.trigger
        XCTAssertEqual(recording, .hold)
        await shortcut(.gesture(.holdEnd), style: .holdAndDoubleTap, at: now + 1)
        let stopped = await controller.recording
        XCTAssertNil(stopped)
        let saved = try await records()
        XCTAssertEqual(saved.first?.result?.text, "Synthetic transcript")
    }

    func testAHoldReleaseNeverStopsADoubleTapSession() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        await shortcut(.gesture(.doubleTap), style: .holdAndDoubleTap, at: now)
        await shortcut(.gesture(.holdEnd), style: .holdAndDoubleTap, at: now + 1)
        let trigger = await controller.recording?.trigger
        XCTAssertEqual(trigger, .doubleTap)
        await shortcut(.gesture(.singleTap), style: .holdAndDoubleTap, at: now + 2)
        let stopped = await controller.recording
        XCTAssertNil(stopped)
    }

    func testStylesGateGestures() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        await shortcut(.gesture(.holdStart), style: .pressToToggle, at: now)
        var active = await controller.recording
        XCTAssertNil(active, "press-to-toggle ignores holds")
        await shortcut(.press, style: .pressToToggle, at: now)
        active = await controller.recording
        XCTAssertEqual(active?.trigger, .press)
        await shortcut(.press, style: .pressToToggle, at: now + 1)
        active = await controller.recording
        XCTAssertNil(active)
    }

    func testImportValidationRejectsUnsupportedFiles() throws {
        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertThrowsError(try DesktopHostImport.validate(text))
        let empty = directory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        XCTAssertThrowsError(try DesktopHostImport.validate(empty))
    }
}
