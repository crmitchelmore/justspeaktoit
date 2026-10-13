import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostVoiceGenerationTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-generation-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects(),
                                                             shutdownGrace: .milliseconds(60))
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    func testGenerateWithoutPlayback_RetainsAudioForReplayAndExportWithoutNewSynthesis() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic generated text.")
        let wav = try audio()
        let count = VoiceGenerationCounter()
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in
            count.increment()
            return wav
        }
        await finish()
        let result = try await retainedResult()
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.audio.wav, wav)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let ownership = await controller.voiceOutputRecordID
        XCTAssertNil(ownership)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("without playback") == true)
        await controller.playGeneratedVoice(result.id.uuidString)
        await finish()
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let files = try FileManager.default.contentsOfDirectory(atPath:
            directory.appendingPathComponent("VoiceGeneratedPlayback").path)
        XCTAssertTrue(files.isEmpty)
        let destination = directory.deletingLastPathComponent().appendingPathComponent("voice-export-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(count.value, 1)
        await controller.exportGeneratedVoice(result.id.uuidString, path:
            directory.appendingPathComponent("protected.wav").path)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("outside the app") == true)
        let kept = await retained()
        XCTAssertEqual(kept?.id, result.id)
    }

    func testGenerate_ArchivesIndependentAudioThenOptionallyPlaysWithoutHistoryMetadata() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic clipboard fixture.")
        let wav = try audio()
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: true)
        ) { _, _, _ in wav }
        await finish()
        let result = try await retainedResult()
        let root = await controller.store.directory
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names.count, 1)
        let archived = try XCTUnwrap(names.first)
        XCTAssertNotNil(UUID(uuidString: URL(fileURLWithPath: archived).deletingPathExtension().lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(archived)), result.audio.wav)
        let records = try await controller.store.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
    }

    func testSaveFailure_PreservesUsableGeneratedResultAndReportsFailure() async throws {
        let root = await controller.store.directory
        try FileManager.default.removeItem(at: root)
        try Data("synthetic blocked folder".utf8).write(to: root)
        let wav = try audio()
        await controller.generateVoiceSource(
            try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic imported text."),
            options: .init(autoPlay: false, saveToRecordings: true)
        ) { _, _, _ in wav }
        await finish()
        await assertRetained(true)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("could not be saved to recordings") == true)
    }

    func testStopAndShutdown_KeepStalledGenerationCountedAndNeverPublishOrArchiveItsLateResult() async throws {
        let gate = VoiceGenerationGate()
        let wav = try audio()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic cancellation.")
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: true)
        ) { _, _, _ in
            await gate.wait()
            return wav
        }
        let task = await controller.voiceGenerationTask
        await controller.playbackStop()
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in wav }
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("still closing") == true)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        await gate.release()
        await task?.value
        await assertRetained(false)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let root = await controller.store.directory
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSettings_UseCanonicalDefaultsAndKeysAndPreserveVoiceAndPerGenerationSnapshot() async throws {
        let defaults = await controller.voiceOutputSettings()
        XCTAssertEqual(defaults.generationOptions,
                       .init(autoPlay: SpeechGenerationDefaults.autoPlay,
                             saveToRecordings: SpeechGenerationDefaults.saveToRecordings))
        let source = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic owned text.", recordID: UUID())
        let gate = VoiceGenerationGate()
        let wav = try audio()
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in
            await gate.wait()
            return wav
        }
        let owner = await controller.voiceOutputRecordID
        XCTAssertEqual(owner, source.recordID)
        let saved = await controller.saveVoiceGenerationOptions(.init(autoPlay: false, saveToRecordings: true))
        XCTAssertTrue(saved)
        let voice = try XCTUnwrap(DesktopVoiceOutputSettings.voices.last)
        await controller.selectVoiceOutput(voice)
        let selected = await controller.voiceOutputSettings()
        XCTAssertEqual(selected.voice, voice)
        XCTAssertEqual(selected.generationOptions.nativeFlags, 2)
        let encoded = try JSONEncoder().encode(selected)
        let decoded = try JSONDecoder().decode(DesktopVoiceOutputSettings.self, from: encoded)
        XCTAssertEqual(decoded, selected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["ttsAutoPlay"] as? Bool, false)
        XCTAssertEqual(json["ttsSaveToDirectory"] as? Bool, true)
        XCTAssertNil(json["autoPlay"])
        await gate.release()
        await finish()
        let result = try await retainedResult()
        XCTAssertEqual(result.source.recordID, source.recordID)
        XCTAssertEqual(result.voice, defaults.voice)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let root = await controller.store.directory
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await controller.discardGeneratedVoice(for: UUID())
        await assertRetained(true)
        await controller.discardGeneratedVoice(for: try XCTUnwrap(source.recordID))
        await assertRetained(false)
    }

    func testPreferenceWriteFailure_PreservesThePreviousCanonicalOptions() async throws {
        let original = await controller.voiceOutputSettings()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("settings.json"), withIntermediateDirectories: false
        )
        let saved = await controller.saveVoiceGenerationOptions(.init(autoPlay: false, saveToRecordings: true))
        XCTAssertFalse(saved)
        let current = await controller.voiceOutputSettings()
        XCTAssertEqual(current, original)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not save Voice Output settings") == true)
    }

    private func retained() async -> DesktopGeneratedVoiceResult? { await controller.generatedVoice }

    private func retainedResult() async throws -> DesktopGeneratedVoiceResult {
        let value = await retained()
        return try XCTUnwrap(value)
    }

    private func assertRetained(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let value = await retained()
        XCTAssertEqual(value != nil, expected, file: file, line: line)
    }

    private func finish() async {
        let task = await controller.voiceGenerationTask
        await task?.value
    }

    private func audio() throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
    }
}

private final class VoiceGenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor VoiceGenerationGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}
