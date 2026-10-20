import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostVoiceFormatTests: XCTestCase {
    var directory: URL!
    var controller: DesktopHostController<VoiceFormatPlatform>!
    override func setUp() async throws {
        FakeLog.shared.reset(); FakeSpeech.shared.reset(); VoiceFormatProbe.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-format-\(UUID())")
        controller = try DesktopHostController(directory: directory, effects: VoiceFormatEffects(),
                                               shutdownGrace: .milliseconds(60))
        await controller.markReadyForSelfTest()
    }
    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testFormats_AllSourcesGenerateAndRetainedExportKeepCapturedBytesWithoutKeysOrResynthesis() async throws {
        for format in VoiceAudioFormat.allCases {
            for source in VoiceOutputSource.allCases where source != .externalSelection {
                let snapshot = try VoiceOutputSourceSnapshot(source: source, text: "Synthetic format source.",
                    recordID: source == .history ? UUID() : nil)
                let wav = try audio()
                let before = VoiceFormatProbe.shared.counts
                await controller.generateVoiceSource(snapshot, options: .init(
                    autoPlay: false, saveToRecordings: true, format: format)) { input, _, credential in
                    XCTAssertEqual(input, snapshot)
                    let key = try await credential()
                    XCTAssertEqual(key, "synthetic-format-key")
                    VoiceFormatProbe.shared.request()
                    return wav
                }
                await finishGeneration()
                let captured = await controller.generatedVoice
                let result = try XCTUnwrap(captured)
                XCTAssertEqual(result.source, snapshot)
                XCTAssertEqual(result.audio.format, format)
                let expected = try VoiceFormatProbe.shared.encoded(
                    VoiceGeneratedAudio(validating: wav), format: format)
                XCTAssertEqual(result.audio.data, expected.data)
                await controller.playbackStop()
                XCTAssertEqual(VoiceFormatProbe.shared.lastPresentation?.format, format)
                let counts = VoiceFormatProbe.shared.counts
                XCTAssertEqual(zip(counts, before).map { $0.0 - $0.1 },
                               format == .wav ? [0, 0, 1, 1] : [1, 1, 1, 1])
                let root = await controller.store.directory
                let archives = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                let matching = archives.filter { $0.pathExtension == format.fileExtension }
                let archivedBytes = try matching.map { try Data(contentsOf: $0) }
                XCTAssertTrue(archivedBytes.contains(expected.data))
                let records = try await controller.store.records()
                XCTAssertTrue(records.isEmpty)
                await controller.playGeneratedVoice(result.id.uuidString)
                await finishGeneration()
                let destination = directory.deletingLastPathComponent()
                    .appendingPathComponent("synthetic-\(UUID())." + format.fileExtension)
                defer { try? FileManager.default.removeItem(at: destination) }
                try Data("prior synthetic destination".utf8).write(to: destination)
                await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
                await finishExport()
                XCTAssertEqual(try Data(contentsOf: destination), expected.data)
                XCTAssertEqual(VoiceFormatProbe.shared.counts, counts)
                let staging = directory.appendingPathComponent("VoiceGeneratedPlayback")
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
            }
        }
    }

    func testUnsupportedCodec_RefusesBeforeDictionaryCredentialProviderOrDestinationMutation() async throws {
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic blocked format.")
        let wav = try audio()
        let destination = directory.deletingLastPathComponent().appendingPathComponent("blocked-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        let prior = Data("prior synthetic file".utf8); try prior.write(to: destination)
        VoiceFormatProbe.shared.refuse(true)
        let failure = await controller.saveVoiceAudioFormat("mp3")
        XCTAssertTrue(failure?.contains("unavailable") == true)
        let unchanged = await controller.voiceOutputSettings()
        XCTAssertNil(unchanged.format)
        await controller.exportVoiceSource(snapshot, path: destination.path) { _, _, credential in
            _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
        }
        await finishExport()
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: true, saveToRecordings: true, format: .mp3)) { _, _, credential in
            _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
        }
        await finishGeneration()
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [3, 0, 0, 0])
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        let result = await controller.generatedVoice
        XCTAssertNil(result)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let dictionary = await controller.vocabularyLoad
        XCTAssertNil(dictionary)
    }

    func testFreshExport_UsesActualChosenExtensionAndRejectsRetainedRenaming() async throws {
        let snapshot = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic export source.")
        let wav = try audio()
        for format in VoiceAudioFormat.allCases {
            let destination = directory.deletingLastPathComponent()
                .appendingPathComponent("fresh-\(UUID())." + format.fileExtension)
            defer { try? FileManager.default.removeItem(at: destination) }
            await controller.exportVoiceSource(snapshot, path: destination.path) { input, _, credential in
                XCTAssertEqual(input, snapshot)
                _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
            }
            await finishExport()
            let expected = try VoiceFormatProbe.shared.encoded(VoiceGeneratedAudio(validating: wav), format: format)
            XCTAssertEqual(try Data(contentsOf: destination), expected.data)
        }
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: false, saveToRecordings: false, format: .m4a)) { _, _, _ in wav }
        await finishGeneration()
        let retained = await controller.generatedVoice
        let result = try XCTUnwrap(retained)
        let wrong = directory.deletingLastPathComponent().appendingPathComponent("wrong-\(UUID()).mp3")
        let prior = Data("keep prior bytes".utf8); try prior.write(to: wrong)
        defer { try? FileManager.default.removeItem(at: wrong) }
        let counts = VoiceFormatProbe.shared.counts
        await controller.exportGeneratedVoice(result.id.uuidString, path: wrong.path)
        await finishExport()
        XCTAssertEqual(try Data(contentsOf: wrong), prior)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, counts)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Choose .m4a") == true)
    }

    func testFormatPersistence_AbsentUnknownImportedAndRestartValuesRemainLossless() async throws {
        var voice: DesktopVoiceOutputSettings?
        let config = try DesktopConfiguration(values: [VoiceAudioFormat.preferenceKey: AnyCodable(.string("future"))])
        let remaining = try DesktopVoiceOutputSettings.importConfiguration(from: config, into: &voice)
        XCTAssertNil(remaining.values[VoiceAudioFormat.preferenceKey])
        XCTAssertEqual(voice?.format, "future")
        let exported = try DesktopVoiceOutputSettings.exportConfiguration(voice, over: remaining)
        XCTAssertEqual(try VoiceAudioFormat.preference(in: exported.values), "future")
        let restored = try JSONDecoder().decode(DesktopVoiceOutputSettings.self,
            from: JSONEncoder().encode(try XCTUnwrap(voice)))
        XCTAssertEqual(restored.format, "future")
        XCTAssertThrowsError(try VoiceAudioFormat.storedValue(restored.format))
        let failure = await controller.saveVoiceAudioFormat("m4a")
        XCTAssertNil(failure)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.format, "m4a")
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: VoiceFormatEffects())
        let restarted = await controller.voiceOutputSettings()
        XCTAssertEqual(restarted.format, "m4a")
    }

    func testAdvancedEditor_ProjectsSavedAndUnknownFormatsWithoutResettingThemToWAV() async throws {
        let key = VoiceAudioFormat.preferenceKey
        let absent = try await controller.configurationForNativeEditor()
        XCTAssertNil(absent.values[key])
        let failure = await controller.saveVoiceAudioFormat("m4a")
        XCTAssertNil(failure)
        for format in ["m4a", "future-format"] {
            var saved = await controller.voiceOutputSettings()
            saved.format = format
            await controller.saveVoiceOutput(saved)
            let shown = try await controller.configurationForNativeEditor()
            XCTAssertEqual(shown.text(key), format)
            try await controller.saveConfiguration(shown.entries, intent: .persistOnly)
            let after = await controller.voiceOutputSettings()
            XCTAssertEqual(after.format, format)
        }
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    func audio() throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 24_000))
    }
    func finishGeneration() async { let task = await controller.voiceGenerationTask; await task?.value }
    func finishExport() async { let task = await controller.readAloudState.exportTask; await task?.value }
}
