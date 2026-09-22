import Foundation
import XCTest
@testable import SpeakDesktop
import SpeakCore

final class DesktopRecordingTests: XCTestCase {
    func testStreamingRecording_FinalisesHeaderWithoutLosingFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try PCMRecordingFile(url: directory.appendingPathComponent("capture.wav"))
        let first = Data(repeating: 1, count: 3200)
        let second = Data(repeating: 2, count: 3200)
        try file.append(first)
        try file.append(second)
        XCTAssertEqual(try file.finish(), 0.2, accuracy: 0.0001)
        let actual = try Data(contentsOf: file.url)
        XCTAssertEqual(actual, PCMWaveWriter.wavData(pcm: first + second, sampleRate: 16_000))
        XCTAssertThrowsError(try file.append(first))
        XCTAssertThrowsError(try file.finish())
    }

    func testFailedTranscription_RecordSurvivesStoreRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopRecordingStore(directory: directory)
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "recording.wav", modelIdentifier: "openai/gpt-transcribe"
        )
        record.failure = "Network unavailable"
        try await store.save(record)
        let reopened = try DesktopRecordingStore(directory: directory)
        let records = try await reopened.records()
        XCTAssertEqual(records.map(\.id), [record.id])
        XCTAssertEqual(records.first?.failure, "Network unavailable")
        XCTAssertNil(records.first?.result)
    }

    func testDesktopModels_AreCanonicalImplementedModels() {
        XCTAssertFalse(DesktopTranscription.batchModels.isEmpty)
        let expected = OpenAITranscriptionModels.directBatchModelIDs
            .union([CartesiaBatchClient.catalogID, GladiaBatchClient.catalogID])
            .union(SpeechmaticsBatchClient.catalogIDs)
            .union([XAISpeechToText.batchCatalogID])
            .union(GroqBatchClient().supportedModels().map(\.id))
            .union(DeepgramBatchClient().supportedModels().map(\.id))
            .union(ElevenLabsBatchClient().supportedModels().map(\.id))
            .union(GeminiTranscribeModels.directBatchModelIDs)
            .union([MetaMuseVoiceTranscribe.batchCatalogID])
            .union(AzureTranscriptionModels.batchIDs)
            .union(ModelCatalog.batchTranscriptionOptions(forProvider: "mistral").map(\.id))
            .union(ModelCatalog.batchTranscriptionOptions(forProvider: "soniox").map(\.id))
        XCTAssertEqual(Set(DesktopTranscription.batchModels.map(\.id)), expected)
        XCTAssertTrue(DesktopTranscription.batchModels.allSatisfy { option in
            ModelCatalog.batchTranscription.contains(option)
        })
    }

    func testMalformedFrame_DoesNotCorruptRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PCMRecordingFile(url: url)
        XCTAssertThrowsError(try file.append(Data([1])))
        XCTAssertEqual(try file.finish(), 0)
        XCTAssertEqual(try Data(contentsOf: url), PCMWaveWriter.wavData(pcm: Data(), sampleRate: 16_000))
    }

    func testDigitalSilence_DoesNotCountAsSpeech() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PCMRecordingFile(url: url)
        try file.append(Data(repeating: 0, count: 3200))
        XCTAssertTrue(file.isDigitalSilence)
        try file.append(Data([1, 0]))
        XCTAssertFalse(file.isDigitalSilence)
        _ = try file.finish()
    }

    func testInterruptedWAV_IsRecoveredWithoutChangingAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data(repeating: 42, count: 6400)
        let emptyHeader = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(), sampleRate: 16_000))
        try (emptyHeader + payload).write(to: url)
        XCTAssertEqual(try PCMRecordingFile.recoverInterruptedFile(at: url), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: url), PCMWaveWriter.wavData(pcm: payload, sampleRate: 16_000))
    }

    func testCorruptHistory_DoesNotHideValidRecordings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopRecordingStore(directory: directory)
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "capture.wav", modelIdentifier: "openai/whisper-1"
        )
        record.failure = "Retained"
        try await store.save(record)
        try Data("broken JSON".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
        let report = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(report.records.map(\.id), [record.id])
        XCTAssertEqual(report.unreadableFiles, ["corrupt.json"])
    }
}
