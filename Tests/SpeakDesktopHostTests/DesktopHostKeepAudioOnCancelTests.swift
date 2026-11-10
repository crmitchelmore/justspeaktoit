import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostKeepAudioOnCancelTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var effects: TailEffects!
    private var index = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keep-audio-\(UUID().uuidString)")
        effects = TailEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil })
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: DesktopHostModels.all[index].id))
        FakeLog.shared.setKey("synthetic", name: provider.apiKeyIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testKeepAudioOff_ExplicitCancelDeletesAudioAndHistoryRecord() async throws {
        try await configure(keepAudio: false)
        await manual()
        let active = try await activeRecording()
        await controller.cancelTranscription()
        let remaining = await controller.recording?.record.id
        XCTAssertNil(remaining)
        let saved = try await controller.store.records()
        XCTAssertTrue(saved.isEmpty)
        let history = await controller.history
        XCTAssertNil(history[active.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(active).path))
        XCTAssertTrue(effects.transcriptions.isEmpty)
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Recording cancelled. Audio discarded.")
    }

    func testKeepAudioOn_ExplicitCancelRetainsAudioAndHistoryRecord() async throws {
        try await configure(keepAudio: true)
        await manual()
        let active = try await activeRecording()
        await controller.cancelTranscription()
        let saved = try await controller.store.records()
        XCTAssertEqual(saved.map(\.id), [active.id])
        XCTAssertEqual(saved.first?.failure, "Recording cancelled. Audio retained.")
        XCTAssertGreaterThan(try Data(contentsOf: audioURL(active)).count, 44)
        XCTAssertTrue(effects.transcriptions.isEmpty)
    }

    func testKeepAudioOff_SettingIsCapturedAtCancelTime() async throws {
        try await configure(keepAudio: true)
        await manual()
        let kept = try await activeRecording()
        await controller.cancelTranscription()
        try await configure(keepAudio: false)
        await manual()
        let discarded = try await activeRecording()
        await controller.cancelTranscription()
        let saved = try await controller.store.records()
        XCTAssertEqual(saved.map(\.id), [kept.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL(kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(discarded).path))
    }

    func testKeepAudioOff_HandsFreeCancelDeletesAudioAndHistoryRecord() async throws {
        try await configure(keepAudio: false, handsFree: true)
        await shortcut()
        let capture = try XCTUnwrap(effects.capture)
        [Int16](repeating: 2_000, count: 1_600).withUnsafeBufferPointer {
            capture.context.receive($0.baseAddress!, count: $0.count)
        }
        try await wait { await self.controller.recording != nil }
        let active = try await activeRecording()
        await controller.cancelTranscription()
        try await wait { await self.controller.handsFreeState() == .off }
        try await wait { (try? await self.controller.store.records().isEmpty) == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL(active).path))
        XCTAssertTrue(effects.transcriptions.isEmpty)
    }

    private func configure(keepAudio: Bool, handsFree: Bool = false) async throws {
        let configuration = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.keepAudioOnCancel.rawValue: AnyCodable(.bool(keepAudio)),
            "handsFreeDictationEnabled": AnyCodable(.bool(handsFree)),
            "postRecordingTailDuration": AnyCodable(.double(0))
        ])
        try await controller.saveConfiguration(configuration.entries)
    }

    private func manual() async {
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
    }

    private func shortcut() async {
        await controller.shortcut(.init(
            input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
            target: nil, targetExecutablePath: nil, textOutput: Task { FakeTextOutput() },
            modelIndex: index, deviceID: ""
        ))
    }

    private func activeRecording() async throws -> DesktopRecordingStore.Record {
        let record = await controller.recording?.record
        return try XCTUnwrap(record)
    }

    private func audioURL(_ record: DesktopRecordingStore.Record) -> URL {
        directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename)
    }

    private func wait(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Cancelled recording condition timed out.")
        throw DesktopHostError(message: "Cancelled recording condition timed out.")
    }
}

@MainActor
final class DesktopHostOwnedKeepAudioOnCancelTests: XCTestCase {
    func testKeepAudioOff_OwnedCancelDeletesAudioAndHistoryRecord() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let configuration = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.keepAudioOnCancel.rawValue: AnyCodable(.bool(false)),
            "postRecordingTailDuration": AnyCodable(.double(0))
        ])
        try await fixture.host.saveConfiguration(configuration.entries)
        await fixture.toggle()
        let id = try await fixture.active().id
        await fixture.host.cancelTranscription()
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertTrue(records.isEmpty)
        let deleted = await fixture.host.store.isDeleted(id: id)
        XCTAssertTrue(deleted)
        let audio = try FileManager.default.contentsOfDirectory(
            at: fixture.directory.appendingPathComponent("History"), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(id.uuidString) && $0.pathExtension == "wav" }
        XCTAssertTrue(audio.isEmpty)
        XCTAssertTrue(fixture.effects.transcriptions.isEmpty)
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }

    func testKeepAudioDefault_OwnedCancelRetainsAudioAndHistoryRecord() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let id = try await fixture.active().id
        await fixture.host.cancelTranscription()
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertEqual(records.first?.failure, "Recording cancelled. Audio retained.")
        let audio = try await fixture.audio(records[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }
}
