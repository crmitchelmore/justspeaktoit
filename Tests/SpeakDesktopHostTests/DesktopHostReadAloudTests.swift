import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// The shared Read aloud controller, driven through the fake platform with a
// scripted engine and player: no network, audio device or native window.

/// What Read aloud asked of the fake player and engine.
final class FakeSpeech: @unchecked Sendable {
    static let shared = FakeSpeech()
    struct Spoken: Equatable {
        let text: String
        let voice: String
    }

    private let lock = NSLock()
    private var active: FakePlayback.Speech?
    private var log: [String] = []
    private var requests: [Spoken] = []
    private var gate = Gate(open: true)

    var events: [String] { lock.withLock { log } }
    var spoken: [Spoken] { lock.withLock { requests } }

    /// With `holdingSegments`, each segment plays until `releaseSegments`, so
    /// a test can act while one is audible.
    func reset(holdingSegments: Bool = false) {
        lock.withLock {
            active = nil
            log = []
            requests = []
            gate = Gate(open: !holdingSegments)
        }
    }

    func releaseSegments() { lock.withLock { gate }.release() }

    func begin(_ speech: FakePlayback.Speech) -> FakePlayback.Speech {
        lock.withLock {
            active = speech
            log.append("begin")
        }
        return speech
    }

    func spoke(_ request: DeepgramSpeechRequest) {
        lock.withLock { requests.append(Spoken(text: request.text, voice: request.voice.id)) }
    }

    /// Refuses segments of an ended speech, and stops when its task is cancelled.
    func play(_ speech: FakePlayback.Speech) async throws -> TimeInterval {
        let gate = try lock.withLock { () -> Gate in
            guard active == speech else { throw CancellationError() }
            log.append("play")
            return self.gate
        }
        await gate.pass()
        try Task.checkCancellation()
        guard lock.withLock({ active == speech }) else { throw CancellationError() }
        return 1
    }

    func end(_ speech: FakePlayback.Speech) {
        lock.withLock {
            guard active == speech else { return }
            active = nil
            log.append("end")
        }
    }
}

extension FakePlayback: DesktopHostSpeechPlayback {
    struct Speech: Hashable, Sendable {
        let recordID: UUID
        let id = UUID()
    }

    func beginSpeech(recordID: UUID) throws -> Speech { FakeSpeech.shared.begin(Speech(recordID: recordID)) }
    func playToCompletion(_ speech: Speech, path: String) async throws -> TimeInterval {
        try await FakeSpeech.shared.play(speech)
    }
    func endSpeech(_ speech: Speech) { FakeSpeech.shared.end(speech) }
}

/// Behaves like the shared engine at its boundaries: an empty key stops it
/// before anything is spoken, and each request plays once through `play`.
struct FakeVoiceOutput: DesktopHostVoiceOutput {
    func speak(
        _ request: DeepgramSpeechRequest,
        credential: @Sendable () async throws -> String,
        through play: @escaping @Sendable (URL) async throws -> TimeInterval
    ) async throws -> DeepgramVoiceOutput.Outcome {
        guard !(try await credential()).isEmpty else { throw DeepgramSpeechError.missingCredential }
        FakeSpeech.shared.spoke(request)
        _ = try await play(URL(fileURLWithPath: "/speech/segment.wav"))
        return .nothingToSpeak
    }
}

extension FakePlatform: DesktopHostReadAloudPlatform {
    typealias ReadAloudState = DesktopHostReadAloudState<FakePlayback.Speech, FakeVoiceOutput>
    static func makeVoiceOutput(stagingDirectory directory: URL) throws -> FakeVoiceOutput { FakeVoiceOutput() }
    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        _ = try await credential()
        try Task.checkCancellation()
        return try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
    }
    static let deepgramKeyHint = "save it in the test"
}

final class DesktopHostReadAloudTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var record: UUID!
    private let deepgramKey = VoiceOutputProvider.deepgram.apiKeyIdentifier
    /// Over Deepgram's 2,000-character request limit, so it is spoken in segments.
    private let longText = String(
        repeating: String(repeating: "Read aloud speaks this sentence ", count: 30) + "to the end. ", count: 3
    )

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("read-aloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil })
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: DesktopHostModels.all[index].id))
        FakeLog.shared.setKey("synthetic-key", name: credential.apiKeyIdentifier)
        // A saved, selected recording whose transcript is shown.
        for _ in 0..<2 {
            await controller.toggle(
                target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
            )
        }
        let selected = await controller.selectedHistoryID
        record = try XCTUnwrap(selected)
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private var statuses: [String] { FakeLog.shared.allStatuses }

    func testAzureRead_UsesNativePlaybackWithRealHistoryOwnershipAndCleansTemporaryAudioOnStop() async throws {
        try await assertAzureRead(
            voice: .azureNeural(AzureNeuralVoiceCatalog.voices[0]),
            options: VoiceSynthesisOptions(speed: 1.25, pitch: -2)
        )
    }

    func testMAIRead_UsesSharedAzureCredentialAndPreservesRealHistoryOwnershipThroughStop() async throws {
        try await assertAzureRead(
            voice: .azureMAI(AzureMAIVoiceCatalog.voices[0]), options: VoiceSynthesisOptions(useSSML: true)
        )
    }

    private func assertAzureRead(voice: DesktopSpeechVoice, options: VoiceSynthesisOptions) async throws {
        FakeSpeech.shared.reset(holdingSegments: true)
        FakeLog.shared.setKey("synthetic-key:eastus", name: AzureSpeechConfiguration.credentialIdentifier)
        await controller.selectVoiceOutput(voice)
        let saved = await controller.saveVoiceSynthesisOptions(options)
        XCTAssertTrue(saved)
        await controller.readAloud(record.uuidString, text: "Synthetic Azure speech.")
        try await waitFor("native synthetic playback") { FakeSpeech.shared.events.contains("play") }
        let owner = await controller.voiceOutputRecordID
        XCTAssertEqual(owner, record)
        let task = await controller.readAloudState.task
        await controller.playbackStop()
        FakeSpeech.shared.releaseSegments()
        await task?.value
        let stoppedOwner = await controller.voiceOutputRecordID
        XCTAssertNil(stoppedOwner)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let files = try FileManager.default.contentsOfDirectory(atPath:
            directory.appendingPathComponent("VoiceGeneratedPlayback").path)
        XCTAssertTrue(files.isEmpty)
    }

    func testReadAloud_RefusesUnsupportedOrInvalidSavedControlsBeforePlayback() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        for (speed, pitch, ssml) in [(1.25, 0.0, false), (1.0, 2.0, false), (1.0, 0.0, true),
                                    (9.0, 0.0, false), (1.0, 0.5, false)] {
            var stored = DesktopVoiceOutputSettings()
            stored.speed = speed
            stored.pitch = pitch
            stored.useSSML = ssml
            await controller.saveVoiceOutput(stored)
            await controller.readAloud(record.uuidString, text: "This must not be silently normalized.")
            XCTAssertTrue(statuses.last?.hasPrefix("Read aloud failed:") == true)
            XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
            XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
            let retained = await controller.voiceOutputSettings()
            XCTAssertEqual(retained, stored)
        }
    }

    func testVoiceSelection_RetainsIncompatibleOptionsWithoutImplicitReset() async throws {
        let first = try XCTUnwrap(DesktopVoiceOutputSettings.voices.first)
        let last = try XCTUnwrap(DesktopVoiceOutputSettings.voices.last)
        var stored = DesktopVoiceOutputSettings(voice: first)
        stored.speed = 1.25
        await controller.saveVoiceOutput(stored)
        let file = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: file)
        await controller.selectVoiceOutput(last)
        XCTAssertNotEqual(try Data(contentsOf: file), before)
        let retained = await controller.voiceOutputSettings()
        XCTAssertEqual(retained.modelID, last.model.id)
        XCTAssertEqual(retained.voiceID, last.id)
        XCTAssertEqual(retained.speed, stored.speed)
        XCTAssertEqual(retained.pitch, stored.pitch)
        XCTAssertEqual(retained.useSSML, stored.useSSML)
    }

    func testReadAloud_SpeaksEachSegmentWithTheSavedVoiceThenFinishes() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        let voice = try XCTUnwrap(DeepgramSpeechCatalog.fluxVoices.first { $0.id == "flux-kit-en" })
        await controller.saveVoiceOutput(DesktopVoiceOutputSettings(voice: voice))
        XCTAssertEqual(statuses.last, "Read aloud voice saved: \(DesktopVoiceOutputSettings.label(voice)).")
        let segments = SpeechTextSegmenter.segments(longText)
        XCTAssertGreaterThan(segments.count, 1)

        await controller.readAloud(record.uuidString, text: longText)
        XCTAssertTrue(statuses.contains("Reading aloud with Kit…"))
        try await waitFor("the finish") { self.statuses.last == "Finished reading aloud." }
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), segments)
        XCTAssertEqual(Set(FakeSpeech.shared.spoken.map(\.voice)), ["flux-kit-en"])
        XCTAssertEqual(FakeSpeech.shared.events, ["begin"] + segments.map { _ in "play" } + ["end"])
        let state = await controller.readAloudState
        XCTAssertFalse(FakePlatform.isReadingAloud(state))
    }

    func testMissingDeepgramKey_SaysWhereToSaveIt() async throws {
        await controller.readAloud(record.uuidString, text: "Hello there.")
        try await waitFor("the key status") {
            self.statuses.last == "Save a Deepgram API key (save it in the test) to read aloud."
        }
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "end"])
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
    }

    func testPronunciationRendersOnceBeforeDeepgramRequestSegmentation() async throws {
        FakeLog.shared.setKey("deepgram-key", name: deepgramKey)
        let replacement = "LongToken " + String(repeating: "expanded ", count: 200)
        _ = try await controller.vocabularyEvent(kind: 1, payload: DesktopVocabularyWire.encode([
            "save", "", "LongToken", "fixture pronunciation", replacement, "Custom", "false", "true", ""
        ]))
        let input = "LongToken LongToken LongToken."
        let entries = [PronunciationEntry(
            word: "LongToken", pronunciation: "fixture pronunciation", replacement: replacement, caseSensitive: true
        )]
        let rendered = PronunciationRenderer().applyReplacements(to: input, entries: entries)
        let expected = SpeechTextSegmenter.segments(rendered)
        XCTAssertGreaterThan(expected.count, 1)
        await controller.readAloud(record.uuidString, text: input)
        try await waitFor("the pronunciation finish") { self.statuses.last == "Finished reading aloud." }
        XCTAssertEqual(FakeSpeech.shared.spoken.map(\.text), expected)
        XCTAssertTrue(FakeSpeech.shared.spoken.allSatisfy { $0.text.count <= 2_000 })
    }

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
