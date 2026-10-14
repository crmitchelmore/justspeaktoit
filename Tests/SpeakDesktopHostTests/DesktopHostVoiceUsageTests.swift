import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostVoiceUsageTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-usage-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testGenerationPersistsActualObservations_ReplayAndRetainedExportNeverCountAgain() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic input.")
        let audio = try wav()
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, selection, _ in
            Self.syntheticRequest(selection.voice)
            return audio
        }
        await finish()
        let state = await controller.voiceUsage
        XCTAssertEqual(state.records?.count, 1)
        XCTAssertNil(state.records?.first?.historyRecordID)
        let encoded = try Data(contentsOf: directory.appendingPathComponent("VoiceUsage/requests.json"))
        XCTAssertFalse(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains(source.text))
        let retainedResult = await retained()
        let result = try XCTUnwrap(retainedResult)
        await controller.playGeneratedVoice(result.id.uuidString)
        await finish()
        let destination = directory.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("VoiceUsage/requests.json")), encoded)
        let restored = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await restored.showVoiceUsage(text: "Synthetic new estimate", requestID: "fixture")
        let loaded = await restored.voiceUsage
        XCTAssertEqual(loaded.records, state.records)
        await restored.close()
    }

    func testOptOutPersistsCanonicalKeyAndInvalidatesInFlightCaptureEvenAfterReenable() async throws {
        let capture = await controller.beginVoiceUsage(operation: .generate, source: .history, recordID: UUID())
        let operation = try XCTUnwrap(capture)
        let id = operation.capture.begin(voice: .azureMAI(AzureMAIVoiceCatalog.voices[0]),
                                         inputCharacters: 12, usesSSML: false)
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        let settings = await controller.voiceOutputSettings()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(json[VoiceUsagePolicy.trackingPreferenceKey] as? Bool, false)
        let disabled = await controller.beginVoiceUsage(operation: .read, source: .typedText, recordID: nil)
        XCTAssertNil(disabled)
        await controller.saveVoiceUsageTracking(true, requestID: "on")
        operation.capture.finish(id, outcome: .completed, audioDuration: 1)
        await controller.finishVoiceUsage(operation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VoiceUsage").path))
    }

    func testCorruptLedgerIsNeverOverwrittenAndUnpricedResultsStayExplicit() async throws {
        let folder = directory.appendingPathComponent("VoiceUsage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("requests.json")
        let original = Data("synthetic damaged ledger".utf8)
        try original.write(to: path)
        let started = await begin()
        let operation = try XCTUnwrap(started)
        Self.finishSynthetic(operation.capture, voice: .deepgram(DeepgramSpeechCatalog.fluxVoices[0]))
        await controller.finishVoiceUsage(operation)
        let state = await controller.voiceUsage
        XCTAssertTrue(state.loadFailed)
        XCTAssertTrue(state.warning?.contains("unchanged") == true)
        XCTAssertEqual(try Data(contentsOf: path), original)
        let record = try XCTUnwrap(operation.capture.records.first)
        XCTAssertNil(record.estimatedCostUSD)
    }

    func testHistoryOwnershipAndPartialFailedAttemptsRemainSeparateFromBilling() async throws {
        let owner = UUID()
        let started = await controller.beginVoiceUsage(operation: .export, source: .history, recordID: owner)
        let operation = try XCTUnwrap(started)
        Self.finishSynthetic(operation.capture, voice: .azureMAI(AzureMAIVoiceCatalog.voices[0]))
        let failed = operation.capture.begin(voice: .deepgram(DeepgramSpeechCatalog.fluxVoices[0]),
                                             inputCharacters: 17, usesSSML: false)
        operation.capture.finish(failed, outcome: .cancelled)
        await controller.finishVoiceUsage(operation)
        let state = await controller.voiceUsage
        XCTAssertEqual(state.records?.map(\.historyRecordID), [owner, owner])
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains("cancelled: 1"))
        XCTAssertTrue(summary.contains("not charges"))
        XCTAssertTrue(summary.contains("may still be billed"))
        XCTAssertTrue(summary.contains(owner.uuidString))
    }

    func testLedgerWriteFailureKeepsMemoryUsageAndReportsItWithoutBlockingSynthesis() async throws {
        let folder = directory.appendingPathComponent("VoiceUsage")
        try Data("synthetic blocked directory".utf8).write(to: folder)
        let started = await begin()
        let operation = try XCTUnwrap(started)
        Self.finishSynthetic(operation.capture, voice: .azureMAI(AzureMAIVoiceCatalog.voices[0]))
        await controller.finishVoiceUsage(operation)
        let state = await controller.voiceUsage
        XCTAssertEqual(state.records?.count, 1)
        XCTAssertTrue(state.warning?.contains("only in memory") == true)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("only in memory") == true)
        XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), "synthetic blocked directory")
    }

    private func begin() async -> DesktopVoiceUsageOperation? {
        await controller.beginVoiceUsage(operation: .generate, source: .typedText, recordID: nil)
    }

    private func retained() async -> DesktopGeneratedVoiceResult? { await controller.generatedVoice }
    private func finish() async { await controller.voiceGenerationTask?.value }

    private func wav() throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0, 3, 0]), sampleRate: 24_000))
    }

    private static func syntheticRequest(_ voice: DesktopSpeechVoice) {
        if let capture = VoiceSynthesisUsage.capture { finishSynthetic(capture, voice: voice) }
    }

    private static func finishSynthetic(_ capture: VoiceSynthesisUsage.Capture, voice: DesktopSpeechVoice) {
        let id = capture.begin(voice: voice, inputCharacters: 16, usesSSML: false)
        capture.finish(id, outcome: .completed, audioDuration: 3.0 / 24_000)
    }
}
