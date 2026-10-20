import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// The remaining `DesktopHostReadAloudTests` cases, split out of
// `DesktopHostReadAloudTests.swift` to keep that type's body under the
// pinned type-length limit. Shares the fixtures, properties and helpers
// declared there.
extension DesktopHostReadAloudTests {
    /// Stop ends the speech while a segment plays: nothing more is spoken and
    /// the stop is reported once, by Stop, never overwritten by the reader.
    func testStop_WhileASegmentPlays_ReportsOneStopAndSpeaksNothingMore() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        FakeSpeech.shared.reset(holdingSegments: true)
        await controller.readAloud(record.uuidString, text: longText)
        try await waitFor("the first segment") { FakeSpeech.shared.events.contains("play") }
        await controller.playbackStop()
        FakeSpeech.shared.releaseSegments()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(statuses.filter { $0 == "Reading aloud stopped." }.count, 1)
        XCTAssertEqual(statuses.last, "Reading aloud stopped.")
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let state = await controller.readAloudState
        XCTAssertFalse(FakePlatform.isReadingAloud(state))
    }

    /// History playback and recording each end Read aloud and own the status
    /// line; the ended reader reports nothing.
    func testHistoryPlaybackAndRecording_EndReadAloudSilently() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        FakeSpeech.shared.reset(holdingSegments: true)
        await controller.readAloud(record.uuidString, text: longText)
        try await waitFor("the first segment") { FakeSpeech.shared.events.contains("play") }
        await controller.playbackToggle(record.uuidString)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])

        FakeSpeech.shared.reset(holdingSegments: true)
        await controller.readAloud(record.uuidString, text: longText)
        try await waitFor("the next speech") { FakeSpeech.shared.events.contains("play") }
        let index = await controller.selectedIndex()
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        FakeSpeech.shared.releaseSegments()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(statuses.contains("Reading aloud stopped."))
        XCTAssertFalse(statuses.contains("Finished reading aloud."))
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
    }

    func testReadAloud_RefusesOtherRecordsHiddenRecordsAndEmptyText() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        await controller.readAloud(UUID().uuidString, text: "Hello.")
        await controller.readAloud(record.uuidString, text: " \n\t ")
        XCTAssertEqual(statuses.last, "There is no transcript to read aloud.")
        await controller.searchHistory("no recording matches this")
        await controller.readAloud(record.uuidString, text: "Hello.")
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }

    func testReadAloud_FilteringStopsSegmentsAndRefusesHiddenRecord() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        FakeSpeech.shared.reset(holdingSegments: true)
        await controller.readAloud(record.uuidString, text: longText)
        try await waitFor("the first segment") { FakeSpeech.shared.events.contains("play") }
        let filter = try JSONEncoder().encode(DesktopHistoryFilter(errorsOnly: true))
        let payload = try XCTUnwrap(String(bytes: filter, encoding: .utf8))
        await controller.applyHistoryFilters(payload)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let selected = await controller.selectedHistoryID
        XCTAssertNil(selected)
        FakeSpeech.shared.releaseSegments()
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.readAloud(record.uuidString, text: longText)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
    }

    func testVoiceSetting_PersistsAndRetiredVoicesResolveThroughTheCatalogue() async throws {
        let unset = await controller.voiceOutputSettings()
        XCTAssertEqual(unset.voice, DeepgramSpeechCatalog.resolvedSelection(modelID: nil, voiceID: nil).voice)
        let voice = try XCTUnwrap(DesktopVoiceOutputSettings.voices.last)
        await controller.saveVoiceOutput(DesktopVoiceOutputSettings(voice: voice))
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.voice, voice)
        let retired = DesktopVoiceOutputSettings(modelID: "aura-0", voiceID: "deepgram/retired-voice")
        XCTAssertTrue(DesktopVoiceOutputSettings.voices.contains(retired.voice))
    }

    func testTypedAndClipboardSources_KeepTextSnapshotAndNeverBorrowHistoryOwner() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic typed source")
        await controller.readVoiceSource(snapshot)
        try await waitFor("typed finish") { self.statuses.last == "Finished reading aloud." }
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), [snapshot.text])
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let selected = await selectedRecord()
        XCTAssertEqual(selected, record)
        FakeSpeech.shared.reset()
        let clipboard = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic clipboard snapshot")
        await controller.readVoiceSource(clipboard)
        try await waitFor("clipboard finish") { FakeSpeech.shared.events.last == "end" }
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), [clipboard.text])
    }

    private func selectedRecord() async -> UUID? { await controller.selectedHistoryID }

    func testVoiceExport_WritesChosenWAVWithoutPlaybackOrChangingHistory() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("voice-export-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let snapshot = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic export snapshot")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
        await controller.exportVoiceSource(snapshot, path: target.path) { captured, _, _ in
            XCTAssertEqual(captured, snapshot)
            return wav
        }
        try await waitFor("export finish") { self.statuses.last == "Voice audio exported as WAV." }
        XCTAssertEqual(try Data(contentsOf: target), wav)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let selected = await selectedRecord()
        XCTAssertEqual(selected, record)
    }

    func testVoiceExport_StopAndNewerGenerationNeverPublishStaleFile() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("voice-stale-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let original = Data("existing destination".utf8)
        try original.write(to: target)
        let gate = Gate(open: false)
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic export")
        await controller.exportVoiceSource(snapshot, path: target.path) { _, _, _ in
            await gate.pass()
            return Data("stale result".utf8)
        }
        await controller.playbackStop()
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        await controller.readVoiceSource(snapshot)
        gate.release()
        try await waitFor("current speech") { FakeSpeech.shared.events.last == "end" }
        try await waitFor("operations ended") { await self.controller.activeOperations == 0 }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(statuses.contains("Voice audio exported as WAV."))
    }

    func testVoiceExport_CloseAndInvalidDestinationCannotPublish() async throws {
        let protected = directory.appendingPathComponent("recording.wav")
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic export")
        await controller.exportVoiceSource(snapshot, path: protected.path) { _, _, _ in
            XCTFail("Protected path reached synthesis")
            return Data()
        }
        XCTAssertEqual(statuses.last, "Choose an export location outside the app's data folder.")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("voice-close-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let gate = Gate(open: false)
        await controller.exportVoiceSource(snapshot, path: target.path) { _, _, _ in
            await gate.pass()
            return Data("late result".utf8)
        }
        let closing = Task { await self.controller.close() }
        try await waitFor("close admission") { await self.controller.closed }
        gate.release()
        _ = await closing.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
