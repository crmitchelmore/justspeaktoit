import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

extension DesktopHostVoicePronunciationTests {
    func testCompletedVoice_ClosePreservesCapturedResultButRefusesEveryClosedAction() async throws {
        let sources = try await sourcesWithHistory()
        let original = try XCTUnwrap(sources.last)
        await generate(original)
        let before = try await generated()
        let requests = VoicePronunciationProbe.shared.calls.count
        let keys = VoicePronunciationProbe.shared.keys
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
        let statuses = FakeLog.shared.allStatuses
        let after = try await generated()
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.source, original)
        XCTAssertEqual(after.voice, before.voice)
        XCTAssertEqual(after.options, before.options)
        XCTAssertEqual(after.audio.wav, before.audio.wav)
        XCTAssertEqual(after.audio.sampleRate, before.audio.sampleRate)
        XCTAssertEqual(after.audio.duration, before.audio.duration)
        let destination = exportDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let prior = Data("Synthetic destination must remain complete.".utf8)
        try prior.write(to: destination)
        await controller.playGeneratedVoice(before.id.uuidString)
        await controller.exportGeneratedVoice(before.id.uuidString, path: destination.path)
        await controller.readVoiceSource(original)
        await controller.readVoiceSource(try .init(source: .typedText, text: "Token"))
        await controller.generateVoiceSource(
            original, options: .init(autoPlay: true, saveToRecordings: true)
        ) { _, _, _ in XCTFail("Closed generation reached a provider."); throw CancellationError() }
        await controller.exportVoiceSource(original, path: destination.path) { _, _, _ in
            XCTFail("Closed export reached a provider."); throw CancellationError()
        }
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, requests)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, keys)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let retained = try await generated()
        XCTAssertEqual(retained.id, before.id)
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testCompletedVoice_StopBeforeProviderSettlesWithoutKeysAndCloseReportsNoUnfinishedWork() async throws {
        let original = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await generate(original)
        let before = try await generated()
        let (gate, load) = try await heldDictionary()
        VoicePronunciationProbe.shared.reset()
        VoicePronunciationProbe.shared.install { _ in
            XCTFail("Cancelled preparation reached the provider.")
            return try VoicePronunciationProbe.audio()
        }
        let destination = exportDestination()
        let pending = try await admit(1, source: original, destination: destination)
        await controller.playbackStop()
        XCTAssertTrue(pending.isCancelled)
        await gate.release()
        _ = try await load.value
        await pending.value
        await assertSettled()
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
        XCTAssertTrue(VoicePronunciationProbe.shared.calls.isEmpty)
        XCTAssertTrue(VoicePronunciationProbe.shared.keys.isEmpty)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let after = try await generated()
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.source, original)
        XCTAssertEqual(after.audio.wav, before.audio.wav)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertPlaybackFilesEmpty()
    }

    func testCompletedVoice_CloseDuringAdmittedProviderKeepsPriorResultAndAllOwnershipUntilTeardown() async throws {
        let original = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await generate(original)
        let before = try await generated()
        let entered = expectation(description: "Replacement provider admitted")
        let gate = VoicePronunciationGate()
        let late = try VoicePronunciationProbe.audio()
        VoicePronunciationProbe.shared.install { _ in
            entered.fulfill()
            await gate.wait()
            return late
        }
        let replacement = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Token replacement")
        await controller.generateVoiceSource(
            replacement, options: .init(autoPlay: true, saveToRecordings: true)
        ) { input, selection, credential in
            try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                input, selection: selection, credential: credential)
        }
        await fulfillment(of: [entered], timeout: 3)
        let operation = await controller.voiceGenerationTask
        let pending = try XCTUnwrap(operation)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        XCTAssertTrue(pending.isCancelled)
        let whileClosing = try await generated()
        XCTAssertEqual(whileClosing.id, before.id)
        XCTAssertEqual(whileClosing.audio.wav, before.audio.wav)
        let active = await controller.activeOperations
        XCTAssertEqual(active, 1)
        let statuses = FakeLog.shared.allStatuses
        await gate.release()
        await pending.value
        let after = try await generated()
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.source, original)
        XCTAssertEqual(after.audio.wav, before.audio.wav)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.text),
                       ["Token Token", "Token Token replacement"])
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [voice.apiKeyIdentifier, voice.apiKeyIdentifier])
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let recordings = await controller.store.directory
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recordings.path).isEmpty)
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }
}
