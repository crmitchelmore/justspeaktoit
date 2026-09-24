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
}
