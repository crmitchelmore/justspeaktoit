import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

extension DesktopHostVoiceFormatTests {
    func testInFlightFormatVoiceAndSource_AreImmutableAfterLaterSettingsChanges() async throws {
        let gate = VoiceFormatGate()
        let owner = UUID()
        let snapshot = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic original.", recordID: owner)
        let original = await controller.voiceOutputSettings()
        let wav = try audio()
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: false, saveToRecordings: false, format: .mp3)) { input, selection, credential in
            XCTAssertEqual(input, snapshot)
            XCTAssertEqual(selection.voice, .deepgram(original.voice))
            _ = try await credential(); VoiceFormatProbe.shared.request()
            await gate.wait()
            return wav
        }
        await gate.waitUntilEntered()
        let failure = await controller.saveVoiceAudioFormat("wav")
        XCTAssertNil(failure)
        await controller.selectVoiceOutput(DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0]))
        await gate.release()
        await finishGeneration()
        let captured = await controller.generatedVoice
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.audio.format, .mp3)
        XCTAssertEqual(result.voice, .deepgram(original.voice))
        XCTAssertEqual(result.source, snapshot)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.format, "wav")
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 1, 1, 1])
    }

    func testStoppedAndClosedLateConversion_RemainsCountedAndCannotReplaceOrArchiveRetainedResult() async throws {
        let snapshot = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic conversion cancellation.")
        let wav = try audio()
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: false, saveToRecordings: false)) { _, _, _ in wav }
        await finishGeneration()
        let previous = await controller.generatedVoice
        let prior = try XCTUnwrap(previous)
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.hold(gate)
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: true, saveToRecordings: true, format: .m4a)) { _, _, credential in
            _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
        }
        await gate.waitUntilEntered()
        let task = await controller.voiceGenerationTask
        await controller.playbackStop()
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: false, saveToRecordings: false)) { _, _, _ in XCTFail("Admitted while closing."); return wav }
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        await gate.release(); await task?.value
        let kept = await controller.generatedVoice
        XCTAssertEqual(kept?.id, prior.id)
        XCTAssertEqual(kept?.audio.data, prior.audio.data)
        let root = await controller.store.directory
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 1, 1, 1])
    }

    func testNativeConversionFailure_PreservesPriorResultAndNeverPublishesPartialDestination() async throws {
        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic codec failure.")
        let wav = try audio()
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: false, saveToRecordings: false)) { _, _, _ in wav }
        await finishGeneration()
        let previous = await controller.generatedVoice
        VoiceFormatProbe.shared.failConversion()
        await controller.generateVoiceSource(snapshot, options: .init(
            autoPlay: true, saveToRecordings: true, format: .mp3)) { _, _, _ in wav }
        await finishGeneration()
        let retained = await controller.generatedVoice
        XCTAssertEqual(retained?.id, previous?.id)
        XCTAssertEqual(retained?.audio.data, previous?.audio.data)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("native codec failure") == true)
        let destination = directory.deletingLastPathComponent().appendingPathComponent("failed-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        let bytes = Data("unchanged synthetic target".utf8); try bytes.write(to: destination)
        await controller.exportVoiceSource(snapshot, path: destination.path) { _, _, _ in wav }
        await finishExport()
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }

    func testExportStopWhileCodecIsSuspended_PreservesWholeExistingDestination() async throws {
        try await cancelledExport(close: false)
    }

    func testExportCloseWhileCodecIsSuspended_KeepsOwnedWorkerUntilItReturns() async throws {
        try await cancelledExport(close: true)
    }

    func testStoppedCompressedExport_RefusesReplacementAndGenerationUntilNativeTeardown() async throws {
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.hold(gate)
        let wav = try audio()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic bounded conversion.")
        let destination = directory.deletingLastPathComponent().appendingPathComponent("bounded-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        let prior = Data("prior complete synthetic file".utf8); try prior.write(to: destination)
        await controller.exportVoiceSource(source, path: destination.path) { _, _, credential in
            _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
        }
        await gate.waitUntilEntered()
        let task = await controller.readAloudState.exportTask
        await controller.playbackStop()
        await controller.exportVoiceSource(source, path: destination.path) { _, _, _ in
            XCTFail("A second native export was admitted before teardown."); return wav
        }
        await controller.generateVoiceSource(source, options: .init(
            autoPlay: false, saveToRecordings: false, format: .m4a)) { _, _, _ in
            XCTFail("Generation overlapped the held native export."); return wav
        }
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 1, 1, 1])
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("still closing") == true)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        await gate.release(); await task?.value
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        let slot = await controller.readAloudState.codecOperationID
        XCTAssertNil(slot)
        await controller.exportVoiceSource(source, path: destination.path) { _, _, credential in
            _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
        }
        await finishExport()
        let expected = try VoiceFormatProbe.shared.encoded(VoiceGeneratedAudio(validating: wav), format: .mp3)
        XCTAssertEqual(try Data(contentsOf: destination), expected.data)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [2, 2, 2, 2])
    }

    func testFormatWriteFailure_KeepsPreviousUnknownValueAndOtherVoiceChoices() async throws {
        var original = await controller.voiceOutputSettings()
        original.format = "future-format"
        await controller.saveVoiceOutput(original)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("settings.json"), withIntermediateDirectories: false)
        let failure = await controller.saveVoiceAudioFormat("m4a")
        XCTAssertNotNil(failure)
        let kept = await controller.voiceOutputSettings()
        XCTAssertEqual(kept, original)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    func testCodecDiscovery_CloseKeepsWorkerCountedWithoutPersistingOrAdmittingAnotherQuery() async throws {
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.holdAvailability(gate)
        let owner = try XCTUnwrap(controller)
        let save = Task { await owner.saveVoiceAudioFormat("mp3") }
        await gate.waitUntilEntered()
        let duplicate = await controller.saveVoiceAudioFormat("m4a")
        XCTAssertTrue(duplicate?.contains("still closing") == true)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        await gate.release()
        let failure = await save.value
        XCTAssertNotNil(failure)
        let kept = await controller.voiceOutputSettings()
        XCTAssertNil(kept.format)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    func testCodecDiscovery_LaterSettingsFenceTheSuspendedSaveWithoutOverwritingThem() async throws {
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.holdAvailability(gate)
        let owner = try XCTUnwrap(controller)
        let save = Task { await owner.saveVoiceAudioFormat("mp3") }
        await gate.waitUntilEntered()
        var later = await controller.voiceOutputSettings()
        later.autoPlay = false; later.format = "future-format"
        await controller.saveVoiceOutput(later)
        await gate.release()
        let failure = await save.value
        XCTAssertTrue(failure?.contains("changed during") == true)
        let kept = await controller.voiceOutputSettings()
        XCTAssertEqual(kept, later)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    func testCodecDiscovery_StopKeepsAdmissionOccupiedUntilTeardownThenAllowsReplacement() async throws {
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.holdAvailability(gate)
        let owner = try XCTUnwrap(controller)
        let save = Task { await owner.saveVoiceAudioFormat("mp3") }
        await gate.waitUntilEntered()
        await controller.playbackStop()
        let refused = await controller.saveVoiceAudioFormat("m4a")
        XCTAssertTrue(refused?.contains("still closing") == true)
        await gate.release()
        let cancelled = await save.value
        XCTAssertNotNil(cancelled)
        let unchanged = await controller.voiceOutputSettings()
        XCTAssertNil(unchanged.format)
        let replacement = await controller.saveVoiceAudioFormat("m4a")
        XCTAssertNil(replacement)
        let kept = await controller.voiceOutputSettings()
        XCTAssertEqual(kept.format, "m4a")
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [2, 0, 0, 0])
    }

    func testCodecDiscovery_SettingsChangedThenRestoredStillInvalidateEarlierAdmission() async throws {
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.holdAvailability(gate)
        let owner = try XCTUnwrap(controller)
        let original = await owner.voiceOutputSettings()
        let save = Task { await owner.saveVoiceAudioFormat("mp3") }
        await gate.waitUntilEntered()
        var intermediate = original; intermediate.autoPlay = false
        await owner.saveVoiceOutput(intermediate)
        await owner.saveVoiceOutput(original)
        await gate.release()
        let failure = await save.value
        XCTAssertTrue(failure?.contains("changed during") == true)
        let kept = await owner.voiceOutputSettings()
        XCTAssertEqual(kept, original)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    func testCodecDiscovery_ImportedFormatChangedThenRestoredStillInvalidatesEarlierAdmission() async throws {
        let initial = await controller.saveVoiceAudioFormat("wav")
        XCTAssertNil(initial)
        let original = await controller.voiceOutputSettings()
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.holdAvailability(gate)
        let owner = try XCTUnwrap(controller)
        let save = Task { await owner.saveVoiceAudioFormat("mp3") }
        await gate.waitUntilEntered()
        let file = directory.appendingPathComponent("synthetic-format-import.json")
        for format in ["future-format", "wav"] {
            let preferences = try DesktopConfiguration(values: [
                VoiceAudioFormat.preferenceKey: AnyCodable(.string(format))
            ])
            let document = DesktopConfigurationDocument(preferences: preferences)
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
            try await controller.importConfiguration(path: file.path)
        }
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, original)
        await gate.release()
        let failure = await save.value
        XCTAssertTrue(failure?.contains("changed during") == true)
        let kept = await controller.voiceOutputSettings()
        XCTAssertEqual(kept, original)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 0, 0, 0])
    }

    private func cancelledExport(close: Bool) async throws {
        let gate = VoiceFormatGate(); VoiceFormatProbe.shared.hold(gate)
        let wav = try audio()
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic held export.")
        let destination = directory.deletingLastPathComponent().appendingPathComponent("held-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: destination) }
        let prior = Data("prior whole synthetic audio".utf8); try prior.write(to: destination)
        await controller.exportVoiceSource(source, path: destination.path) { _, _, credential in
            _ = try await credential(); VoiceFormatProbe.shared.request(); return wav
        }
        await gate.waitUntilEntered()
        let task = await controller.readAloudState.exportTask
        if close {
            let report = await controller.close()
            XCTAssertEqual(report.unfinishedOperations, 1)
        } else { await controller.playbackStop() }
        await gate.release(); await task?.value
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        XCTAssertEqual(VoiceFormatProbe.shared.counts, [1, 1, 1, 1])
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let result = await controller.generatedVoice
        XCTAssertNil(result)
    }
}
