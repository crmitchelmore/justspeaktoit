import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

extension DesktopHostVoicePronunciationTests {
    // existing owned test covering generation-mid-flight dictionary/voice edits; no behavior change.
    // swiftlint:disable:next function_body_length
    func testLaterDictionaryAndVoiceEdits_DoNotRetagCapturedJobOrRetainedPlaybackAndExport() async throws {
        let entered = expectation(description: "Prepared provider input is captured")
        let gate = VoicePronunciationGate()
        let wav = try VoicePronunciationProbe.audio()
        VoicePronunciationProbe.shared.install { call in
            XCTAssertEqual(call.source.text, "Token Token")
            entered.fulfill()
            await gate.wait()
            return wav
        }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Token")
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { input, selection, credential in
            try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                input, selection: selection, credential: credential)
        }
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceGenerationTask
        try await saveEntries([.init(word: "Token", pronunciation: "new", replacement: "New")])
        await controller.selectVoiceOutput(.openai(.highDefinition, OpenAITTSCatalog.voices[0]))
        await gate.release()
        await pending?.value
        let result = try await generated()
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.voice, voice)
        XCTAssertEqual(result.audio.wav, wav)
        let usageBefore = await controller.voiceUsage.records
        XCTAssertEqual(usageBefore?.first?.modelID, voice.modelID)
        XCTAssertEqual(usageBefore?.first?.inputCharacters, "Token Token".unicodeScalars.count)
        XCTAssertEqual(usageBefore?.first?.source, source.source)
        let damaged = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic damaged after generation".utf8)
        try raw.write(to: damaged)
        await controller.installPronunciationLoad(nil)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Retained output read a credential") }
        await controller.playGeneratedVoice(result.id.uuidString)
        let playback = await controller.voiceGenerationTask
        await playback?.value
        let destination = exportDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(try Data(contentsOf: damaged), raw)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 1)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [voice.apiKeyIdentifier])
        let usageAfter = await controller.voiceUsage.records
        XCTAssertEqual(usageAfter, usageBefore)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testCorruptDictionary_AllFreshOperationsRefuseBeforeCredentialsAndPreserveTheFile() async throws {
        let file = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic corrupt dictionary".utf8)
        try raw.write(to: file)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await assertFreshOperationsRefused(source)
        XCTAssertEqual(try Data(contentsOf: file), raw)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0.contains("Pronunciation dictionary could not be loaded")
        })
    }

    func testFailedReload_DoesNotSpeakStalePreviouslyLoadedEntriesOrOverwriteCorruption() async throws {
        let vocabulary = try await controller.vocabularyStore()
        let file = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic failed reload".utf8)
        try raw.write(to: file)
        do {
            try await vocabulary.reload()
            XCTFail("Corrupt dictionary reload succeeded")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        await assertFreshOperationsRefused(try .init(source: .clipboard, text: "Token"))
        XCTAssertEqual(try Data(contentsOf: file), raw)
    }

    func testEmptySilentAndOversizedRenderedText_NeverReachesCredentialsOrRequests() async throws {
        XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .typedText, text: " \n "))
        for text in ["[BLANK_AUDIO]", " \n[blank_audio]\t "] {
            await assertFreshOperationsRefused(try .init(source: .textFile, text: text))
        }
        for replacement in [" ", "[blank_audio]", String(repeating: "x", count: 100_001), "\0"] {
            try await saveEntries([.init(word: "Token", pronunciation: "synthetic", replacement: replacement)])
            await assertFreshOperationsRefused(try .init(source: .typedText, text: "Token"))
        }
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("There is no text") })
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("100,000") })
    }

    func testHeldDictionaryLoad_StopCancelsReadGenerateAndDirectExportWithoutProviderWork() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Token")
        for action in 0..<3 {
            let (gate, load) = try await heldDictionary()
            let destination = exportDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let pending = try await admit(action, source: source, destination: destination)
            let active = await controller.activeOperations
            XCTAssertEqual(active, 1)
            await controller.playbackStop()
            XCTAssertTrue(pending.isCancelled)
            let statuses = FakeLog.shared.allStatuses
            await gate.release()
            _ = try await load.value
            await pending.value
            XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
            XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
            let retained = await controller.generatedVoice
            XCTAssertNil(retained)
            try assertPlaybackFilesEmpty()
            await assertSettled()
        }
    }

    func testHeldDictionaryLoad_CloseCannotPublishRequestOrLeaveOwnedWorkAfterRelease() async throws {
        let (gate, load) = try await heldDictionary()
        let destination = exportDestination()
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        let pending = try await admit(1, source: source, destination: destination)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        await controller.close()
        XCTAssertTrue(pending.isCancelled)
        let statuses = FakeLog.shared.allStatuses
        await gate.release()
        _ = try await load.value
        await pending.value
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
        XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
        let retained = await controller.generatedVoice
        XCTAssertNil(retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await assertSettled()
    }

    func testHeldDictionaryLoad_NewerReadOwnsStatusAndOnlyItsPreparedRequestIsAdmitted() async throws {
        let (gate, load) = try await heldDictionary()
        await controller.readVoiceSource(try .init(source: .clipboard, text: "Token old"))
        let previous = await controller.readAloudState.task
        let old = try XCTUnwrap(previous)
        let replacement = try VoiceOutputSourceSnapshot(source: .textFile, text: "Token new")
        await controller.readVoiceSource(replacement)
        let current = await controller.readAloudState.task
        let newer = try XCTUnwrap(current)
        XCTAssertTrue(old.isCancelled)
        await gate.release()
        _ = try await load.value
        await old.value
        await newer.value
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.text), ["Token Token new"])
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.first?.source.source, .textFile)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [voice.apiKeyIdentifier])
        XCTAssertEqual(FakeLog.shared.allStatuses.filter { $0 == "Finished reading aloud." }.count, 1)
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testProviderFailure_LeavesPreviousOriginalResultWithoutPlaybackArchiveOrPartialPublication() async throws {
        let original = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await generate(original)
        let before = try await generated()
        VoicePronunciationProbe.shared.install { _ in
            throw DesktopHostError(message: "Synthetic provider refusal.")
        }
        await generate(try .init(source: .textFile, text: "Token new"))
        let after = try await generated()
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.source, original)
        XCTAssertEqual(after.audio.wav, before.audio.wav)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.text), ["Token Token", "Token Token new"])
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 2)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Synthetic provider refusal.") == true)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testStoppedOrClosedPreparedGeneration_CannotPublishLateAudioOrReplacePriorResult() async throws {
        let original = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await generate(original)
        let retained = try await generated()
        for close in [false, true] {
            let entered = expectation(description: "Prepared generation reached held synthetic provider")
            let gate = VoicePronunciationGate()
            let wav = try VoicePronunciationProbe.audio()
            VoicePronunciationProbe.shared.install { call in
                XCTAssertEqual(call.source.text, "Token Token next")
                entered.fulfill()
                await gate.wait()
                return wav
            }
            await controller.generateVoiceSource(
                try .init(source: .clipboard, text: "Token next"),
                options: .init(autoPlay: true, saveToRecordings: true)
            ) { input, selection, credential in
                try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                    input, selection: selection, credential: credential)
            }
            await fulfillment(of: [entered], timeout: 3)
            let pending = await controller.voiceGenerationTask
            if close { await controller.close() } else { await controller.playbackStop() }
            let statuses = FakeLog.shared.allStatuses
            await gate.release()
            await pending?.value
            let after = try await generated()
            XCTAssertEqual(after.id, retained.id)
            XCTAssertEqual(after.source, original)
            XCTAssertEqual(after.audio.wav, retained.audio.wav)
            XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
            XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
            let recordings = await controller.store.directory
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recordings.path).isEmpty)
            await assertSettled()
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 3)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 3)
    }
}

private extension DesktopHostVoicePronunciationTests {
    func assertFreshOperationsRefused(_ source: VoiceOutputSourceSnapshot) async {
        await controller.readVoiceSource(source)
        let read = await controller.readAloudState.task
        await read?.value
        await generate(source)
        let destination = exportDestination()
        await controller.exportVoiceSource(source, path: destination.path) { _, _, _ in
            XCTFail("Invalid dictionary/input reached direct-export synthesis")
            throw DesktopHostError(message: "Invalid input reached the synthetic provider.")
        }
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
        XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
        let retained = await controller.generatedVoice
        XCTAssertNil(retained)
        XCTAssertFalse(FakeSpeech.shared.events.contains("play"))
        await assertSettled()
    }
}

extension DesktopHostVoicePronunciationTests {
    func heldDictionary() async throws -> (VoicePronunciationGate, Task<DesktopVocabulary, Error>) {
        let vocabulary = try await controller.vocabularyStore()
        let gate = VoicePronunciationGate()
        let load = Task<DesktopVocabulary, Error> {
            await gate.wait()
            return vocabulary
        }
        await controller.installPronunciationLoad(load)
        return (gate, load)
    }

    func admit(
        _ action: Int, source: VoiceOutputSourceSnapshot, destination: URL
    ) async throws -> Task<Void, Never> {
        if action == 0 {
            await controller.readVoiceSource(source)
            let read = await controller.readAloudState.task
            return try XCTUnwrap(read)
        }
        if action == 1 {
            await controller.generateVoiceSource(
                source, options: .init(autoPlay: false, saveToRecordings: false)
            ) { input, selection, credential in
                try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                    input, selection: selection, credential: credential)
            }
            let generation = await controller.voiceGenerationTask
            return try XCTUnwrap(generation)
        }
        await controller.exportVoiceSource(source, path: destination.path) { input, selection, credential in
            try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                input, selection: selection, credential: credential)
        }
        let export = await controller.readAloudState.exportTask
        return try XCTUnwrap(export)
    }
}
