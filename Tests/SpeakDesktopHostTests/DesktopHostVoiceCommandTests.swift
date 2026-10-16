import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostVoiceCommandTests: XCTestCase {
    private var directory: URL!
    private var effects: VoiceCommandEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-command-\(UUID())")
        effects = VoiceCommandEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopTranscription.provider(for: $0.id) != nil
        })
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func configuration(enabled: Bool = true, triggers: String = "") async throws {
        var entries = try await controller.configuration().entries
        entries[try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "voiceCommandsEnabled" })] =
            enabled ? "1" : "0"
        entries[try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "clipboardInsertionTriggers" })] =
            triggers
        try await controller.saveConfiguration(entries)
    }

    private func recordBatch(target: String? = nil) async throws -> DesktopRecordingStore.Record {
        await controller.toggle(
            target: target, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let records = try await controller.store.records()
        return try XCTUnwrap(records.first)
    }

    func testBatchExpandsBeforeVocabularyAndRetainsOriginal() async throws {
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Synthetic", "Canonical", "Synthetic", "automatic", "", "high", ""
        ]))
        let record = try await recordBatch()
        XCTAssertEqual(record.originalText, "please copy pasta")
        XCTAssertEqual(record.correctedText, "please Canonical clipboard")
        XCTAssertEqual(record.displayText, "please Canonical clipboard")
        XCTAssertEqual(record.lexiconSummary?.applied.count, 1)
        XCTAssertEqual(effects.reads, 1)
        XCTAssertNil(record.failure)
        XCTAssertTrue(effects.base.outputs.isEmpty)
    }

    func testRemotePolishReceivesExpandedCorrectedTextAndAutomaticOutputUsesSavedFinalVariant() async throws {
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Synthetic", "Canonical", "Synthetic", "automatic", "", "high", ""
        ]))
        await controller.savePostProcessing(enabled: true, modelIndex: 0, prompt: "", key: "synthetic-polish-key")
        let record = try await recordBatch(target: "editor")
        XCTAssertEqual(effects.polishInputs, ["please Canonical clipboard"])
        XCTAssertEqual(record.originalText, effects.text)
        XCTAssertEqual(record.correctedText, "please Canonical clipboard")
        XCTAssertEqual(record.processedText, "please Canonical clipboard polished")
        for _ in 0..<100 {
            if !effects.base.outputs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(effects.base.outputs.first?.1, record.processedText)
        XCTAssertEqual(effects.reads, 1)
    }

    func testDisabledAndNonTriggerAndEmptyTranscriptsNeverReadClipboard() async throws {
        try await configuration(enabled: false)
        let disabled = try await recordBatch()
        XCTAssertEqual(disabled.displayText, effects.text)
        try await configuration()
        effects.text = "copypastas and pasted words"
        let unmatched = try await recordBatch()
        XCTAssertEqual(unmatched.displayText, effects.text)
        effects.text = ""
        let empty = try await recordBatch()
        XCTAssertEqual(empty.displayText, "")
        XCTAssertEqual(effects.reads, 0)
    }

    func testCustomTriggersAndEmptyClipboard() async throws {
        try await configuration(triggers: "paste, My snippet")
        effects.text = "MY SNIPPET then paste clipboard"
        effects.clipboard = "captured"
        let expanded = try await recordBatch()
        XCTAssertEqual(expanded.displayText, "captured then captured")
        effects.clipboard = ""
        let empty = try await recordBatch()
        XCTAssertEqual(empty.displayText, effects.text)
        effects.clipboard = nil
        let nonText = try await recordBatch()
        XCTAssertEqual(nonText.displayText, effects.text)
        XCTAssertEqual(effects.reads, 3)
    }

    func testImportedPreferencesControlActualTranscriptionExecution() async throws {
        let file = directory.appendingPathComponent("voice-preferences.json")
        try Data(#"{"version":1,"preferences":{"voiceCommandsEnabled":false}}"#.utf8).write(to: file)
        try await controller.importConfiguration(path: file.path)
        let disabled = try await recordBatch()
        XCTAssertEqual(disabled.displayText, effects.text)
        XCTAssertEqual(effects.reads, 0)
        let preferences = try DesktopConfiguration(values: [
            "voiceCommandsEnabled": AnyCodable(.bool(true)),
            "clipboardInsertionTriggers": AnyCodable(.string("my snippet"))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        effects.text = "my snippet"
        let enabled = try await recordBatch()
        XCTAssertEqual(enabled.displayText, effects.clipboard)
        XCTAssertEqual(effects.reads, 1)
    }

    func testImportAndRetryUseNewRawResultButHistoryNeverReexpands() async throws {
        effects.clipboard = "copy pasta"
        let original = try await recordBatch()
        XCTAssertEqual(original.displayText, "please copy pasta", "Canonical depth limit preserves a cyclic trigger")
        effects.clipboard = "new snapshot"
        await controller.selectHistory(original.id.uuidString)
        await controller.selectTranscriptVariant(.original, identifier: original.id.uuidString)
        await controller.selectTranscriptVariant(.processed, identifier: original.id.uuidString)
        await controller.copyTranscript(original.displayText ?? "", variant: .processed)
        XCTAssertEqual(effects.reads, 1)
        await controller.retryHistory(original.id.uuidString)
        let retried = try await controller.store.record(id: original.id)
        XCTAssertEqual(retried.originalText, "please copy pasta")
        XCTAssertEqual(retried.displayText, "please new snapshot")
        XCTAssertEqual(effects.reads, 2, "Retry expands the new provider result once, not stored History")
        let audio = try await controller.store.audioURL(for: original)
        await controller.importAudio(path: audio.path, modelIndex: batchIndex)
        let records = try await controller.store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.originalText == effects.text && $0.displayText == "please new snapshot" })
        XCTAssertEqual(effects.reads, 3)
        XCTAssertTrue(effects.base.outputs.isEmpty, "Imports and retries have no automatic insertion target")
    }

    func testReadFailurePreservesRawTranscriptAndDoesNotPublishClipboardErrorContents() async throws {
        effects.clipboardError = DesktopHostError(message: "private owner data")
        let record = try await recordBatch()
        XCTAssertEqual(record.originalText, effects.text)
        XCTAssertNil(record.correctedText)
        XCTAssertTrue(record.failure?.contains("Clipboard voice command could not be read") == true)
        XCTAssertFalse(record.failure?.contains("private owner data") == true)
        XCTAssertTrue(effects.base.outputs.isEmpty)
    }

    func testOversizedClipboardIsRejectedWithoutSavingItsContents() async throws {
        effects.clipboard = String(repeating: "x", count: DesktopVoiceCommandClipboardRead.maximumBytes + 1)
        let record = try await recordBatch()
        XCTAssertEqual(record.originalText, effects.text)
        XCTAssertNil(record.correctedText)
        XCTAssertNotNil(record.failure)
        XCTAssertTrue(effects.base.outputs.isEmpty)
    }

    func testCancelAndCloseDuringClipboardReadRetainRawWithoutLateExpansion() async throws {
        for closing in [false, true] {
            effects.clipboardGate = Gate(open: false)
            effects.clipboardEntered.hold()
            await controller.toggle(
                target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
                textOutput: FakeTextOutput()
            )
            let stopping = Task {
                await self.controller.toggle(
                    target: nil, modelIndex: self.batchIndex, deviceID: "", targetExecutablePath: nil,
                    textOutput: FakeTextOutput()
                )
            }
            try await waitForClipboardRead()
            if closing { await controller.close() } else { await controller.cancelTranscription() }
            await stopping.value
            let records = try await controller.store.records()
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.originalText, effects.text)
            XCTAssertNil(record.correctedText)
            XCTAssertNotNil(record.failure)
            effects.clipboardGate?.release()
            XCTAssertTrue(effects.base.outputs.isEmpty)
        }
    }

    private func waitForClipboardRead() async throws {
        for _ in 0..<500 {
            if effects.clipboardEntered.isOpen { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DesktopHostError(message: "Synthetic clipboard read did not start within five seconds.")
    }

    func testLiveSuccessUsesSamePipelineAndFailedLiveNeverReadsClipboard() async throws {
        let profile = DesktopProfileSession.defaults(
            modelIdentifier: "assemblyai/universal-streaming", postProcessing: .init(), language: nil
        )
        for failure in [false, true] {
            let id = UUID()
            let record = DesktopRecordingStore.Record(
                id: id, audioFilename: "\(id).wav", modelIdentifier: profile.modelIdentifier
            )
            try await controller.store.save(record)
            let client = VoiceCommandFinalClient(text: effects.text, fails: failure)
            let session = DesktopLiveSession(client: client, id: id)
            session.start()
            let stopped = DesktopHostController<FakePlatform>.StoppedRecording(
                record: record, duration: 1, target: nil, live: session, profile: profile, textOutput: FakeTextOutput()
            )
            await controller.finishLive(stopped, session: session)
            let saved = try await controller.store.record(id: id)
            XCTAssertEqual(saved.originalText, effects.text)
            XCTAssertEqual(saved.displayText, failure ? effects.text : "please Synthetic clipboard")
            XCTAssertEqual(saved.failure != nil, failure)
        }
        XCTAssertEqual(effects.reads, 1)
    }

    func testClipboardReadBudgetAndCancellationDoNotWaitForUncooperativeOwner() async throws {
        let entered = Gate(open: false)
        let release = Gate(open: false)
        let request = Task {
            try await DesktopVoiceCommandClipboardRead.run(timeout: .milliseconds(25)) {
                entered.release()
                await withCheckedContinuation { continuation in
                    Task.detached {
                        await release.pass()
                        continuation.resume()
                    }
                }
                return "late"
            }
        }
        await entered.pass()
        do { _ = try await request.value; XCTFail("Timeout accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        release.release()
    }
}

private final class VoiceCommandFinalClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    let text: String
    let fails: Bool
    init(text: String, fails: Bool) { self.text = text; self.fails = fails }
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        onTranscript(text, true)
        if fails { onError(DesktopHostError(message: "Synthetic live failure")) }
    }
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? { text }
}
