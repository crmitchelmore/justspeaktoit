import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

extension DesktopHostVoicePronunciationTests {
    func testIPA_CorruptionAndFailedReloadRefuseAllFreshOperationsWithoutReplacingStorage() async throws {
        _ = try await configureIPAVoice()
        let file = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic corrupt IPA dictionary".utf8)
        try raw.write(to: file)
        await assertIPAFreshRefused()
        XCTAssertEqual(try Data(contentsOf: file), raw)
        try await saveEntries([entry])
        let vocabulary = try await controller.vocabularyStore()
        try raw.write(to: file)
        do {
            try await vocabulary.reload()
            XCTFail("Corrupt reload succeeded")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        await assertIPAFreshRefused()
        XCTAssertEqual(try Data(contentsOf: file), raw)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0.contains("Pronunciation dictionary could not be loaded")
        })
    }

    func testIPA_RenderedEmptySilentNullAndFinalBodyExpansionRefuseBeforeKeysAndRequests() async throws {
        _ = try await configureIPAVoice()
        for pronunciation in ["\0", String(repeating: "p", count: 65_536),
                              String(repeating: "&", count: 14_000)] {
            try await saveEntries([.init(word: "Token", pronunciation: pronunciation, caseSensitive: true)])
            await assertIPAFreshRefused()
        }
        for replacement in ["", " \n ", "[blank_audio]", "\0"] {
            try await saveEntries([.init(word: "^Token$", pronunciation: "x",
                                        replacement: replacement, isRegex: true)])
            await assertIPAFreshRefused()
        }
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("SSML") })
        XCTAssertFalse(FakeSpeech.shared.events.contains("play"))
    }

    // Keep captured-input and retained-output invariants in one operation lifecycle.
    // swiftlint:disable:next function_body_length
    func testIPA_CapturedDictionaryAndVoiceRemainFixedAndRetainedReplayExportNeverReprepare() async throws {
        let selected = try await configureIPAVoice()
        let entered = expectation(description: "IPA provider captured its immutable input")
        let gate = VoicePronunciationGate()
        let expected = ipaToken
        let wav = try VoicePronunciationProbe.audio()
        VoicePronunciationProbe.shared.install { call in
            XCTAssertEqual(call.source.text, expected)
            XCTAssertEqual(call.selection.voice, selected)
            entered.fulfill()
            await gate.wait()
            return wav
        }
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Token")
        await controller.generateVoiceSource(
            source,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { input, selection, credential in
            try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                input, selection: selection, credential: credential)
        }
        await fulfillment(of: [entered], timeout: 3)
        let pending = await controller.voiceGenerationTask
        try await saveEntries([.init(word: "Token", pronunciation: "different", replacement: "new")])
        await controller.selectVoiceOutput(voice)
        await gate.release()
        await pending?.value
        let result = try await generated()
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.voice, selected)
        XCTAssertEqual(result.audio.wav, wav)
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.count, 1)
        XCTAssertEqual(usage?.first?.modelID, selected.modelID)
        XCTAssertEqual(usage?.first?.inputCharacters, expected.unicodeScalars.count)
        let file = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic corrupt after IPA generation".utf8)
        try raw.write(to: file)
        await controller.installPronunciationLoad(nil)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Retained result accessed a key") }
        VoicePronunciationProbe.shared.install { _ in
            XCTFail("Retained result resynthesized")
            throw DesktopHostError(message: "Retained result resynthesized")
        }
        await controller.playGeneratedVoice(result.id.uuidString)
        let play = await controller.voiceGenerationTask
        await play?.value
        let destination = exportDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        let export = await controller.readAloudState.exportTask
        await export?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(try Data(contentsOf: file), raw)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 1)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [selected.apiKeyIdentifier])
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, usage)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testIPA_HeldDictionaryStopAcrossActionsAndNewerReadFenceAllStaleProviderWork() async throws {
        let selected = try await configureIPAVoice()
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Token")
        for action in 0..<3 {
            let (gate, load) = try await holdIPADictionary()
            let destination = exportDestination()
            let pending = try await ipaOperation(action, source: source, destination: destination)
            await controller.playbackStop()
            XCTAssertTrue(pending.isCancelled)
            let statuses = FakeLog.shared.allStatuses
            await gate.release()
            _ = try await load.value
            await pending.value
            XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
            XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
            await assertSettled()
        }
        let (gate, load) = try await holdIPADictionary()
        await controller.readVoiceSource(source)
        let old = await controller.readAloudState.task
        await controller.readVoiceSource(try .init(source: .textFile, text: "Token new"))
        let newer = await controller.readAloudState.task
        XCTAssertTrue(old?.isCancelled == true)
        await gate.release()
        _ = try await load.value
        await old?.value
        await newer?.value
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.text), [ipaToken + " new"])
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.first?.source.source, .textFile)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [selected.apiKeyIdentifier])
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testIPA_HeldDictionaryCloseCannotRequestOrPublishAfterRelease() async throws {
        _ = try await configureIPAVoice()
        let (gate, load) = try await holdIPADictionary()
        let destination = exportDestination()
        let pending = try await ipaOperation(
            1, source: .init(source: .typedText, text: "Token"), destination: destination)
        await controller.close()
        XCTAssertTrue(pending.isCancelled)
        let statuses = FakeLog.shared.allStatuses
        await gate.release()
        _ = try await load.value
        await pending.value
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
        XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
        let retained = await controller.generatedVoice
        XCTAssertNil(retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    // Keep failure, cancellation and close cleanup assertions against the same retained result.
    func testIPA_ProviderFailureAndStoppedOrClosedLateAudioPreservePriorResultAndCleanup() async throws {
        _ = try await configureIPAVoice()
        let original = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await generate(original)
        let retained = try await generated()
        VoicePronunciationProbe.shared.install { _ in
            throw DesktopHostError(message: "Synthetic IPA provider failure")
        }
        await generate(original)
        let failed = try await generated()
        XCTAssertEqual(failed.id, retained.id)
        XCTAssertEqual(failed.audio.wav, retained.audio.wav)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Synthetic IPA provider failure") == true)
        for close in [false, true] {
            let entered = expectation(description: "IPA provider admitted before cancellation")
            let gate = VoicePronunciationGate()
            let expected = ipaToken + " late"
            let wav = try VoicePronunciationProbe.audio()
            VoicePronunciationProbe.shared.install { call in
                XCTAssertEqual(call.source.text, expected)
                entered.fulfill()
                await gate.wait()
                return wav
            }
            await controller.generateVoiceSource(
                try .init(source: .textFile, text: "Token late"),
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
            try assertPlaybackFilesEmpty()
            await assertSettled()
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 4)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 4)
    }
}

private extension DesktopHostVoicePronunciationTests {
    func holdIPADictionary() async throws -> (VoicePronunciationGate, Task<DesktopVocabulary, Error>) {
        let vocabulary = try await controller.vocabularyStore()
        let gate = VoicePronunciationGate()
        let task = Task<DesktopVocabulary, Error> {
            await gate.wait()
            return vocabulary
        }
        await controller.installPronunciationLoad(task)
        return (gate, task)
    }

    func assertIPAFreshRefused() async {
        for action in 0..<3 {
            let destination = exportDestination()
            do {
                let pending = try await ipaOperation(
                    action, source: .init(source: .clipboard, text: "Token"), destination: destination)
                await pending.value
            } catch { XCTFail("Invalid input did not reach the owned operation: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
            XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
            let retained = await controller.generatedVoice
            XCTAssertNil(retained)
            await assertSettled()
        }
        do { try assertPlaybackFilesEmpty() } catch { XCTFail("Playback cleanup inspection failed: \(error)") }
    }
}
