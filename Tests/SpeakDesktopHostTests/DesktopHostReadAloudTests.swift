import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// The shared Read aloud controller, driven through the fake platform with a
// scripted engine and player: no network, audio device or native window.
// Fixtures live in DesktopHostReadAloudTestFixtures.swift; the remaining cases
// are in DesktopHostReadAloudTestsVoiceSources.swift, to keep this type under
// the pinned type-length limit.

final class DesktopHostReadAloudTests: XCTestCase {
    // Internal (not private): the voice-source test cases in
    // DesktopHostReadAloudTestsVoiceSources.swift share these across files.
    var directory: URL!
    var controller: DesktopHostController<FakePlatform>!
    var record: UUID!
    let deepgramKey = VoiceOutputProvider.deepgram.apiKeyIdentifier
    /// Over Deepgram's 2,000-character request limit, so it is spoken in segments.
    let longText = String(
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

    // Internal: shared with the voice-source cases in
    // DesktopHostReadAloudTestsVoiceSources.swift.
    func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    var statuses: [String] { FakeLog.shared.allStatuses }

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
}
