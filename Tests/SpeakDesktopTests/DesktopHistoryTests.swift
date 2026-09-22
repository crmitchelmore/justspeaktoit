import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopHistoryTests: XCTestCase {
    func testHistoryLookupAndExport_PreserveUnicodeAndOriginalAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        let store = try DesktopRecordingStore(directory: directory)
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "retained.wav", modelIdentifier: "openai/whisper-1"
        )
        let text = "Café — a saved transcript. 🎙\nSecond line."
        record.result = TranscriptionResult(
            text: text, segments: [], confidence: nil, duration: 1, modelIdentifier: record.modelIdentifier,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        let audio = Data([1, 2, 3, 4])
        try audio.write(to: directory.appendingPathComponent(record.audioFilename))
        try await store.save(record)
        let reopened = try DesktopRecordingStore(directory: directory)
        let saved = try await reopened.record(id: record.id)
        XCTAssertEqual(saved.result?.text, text)
        let audioURL = try await reopened.audioURL(for: saved)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        let exported = root.appendingPathComponent("transcript.txt")
        try await reopened.exportTranscript(id: record.id, to: exported)
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), text)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
    }

    func testAudioPath_RejectsTraversalAndDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopRecordingStore(directory: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder"), withIntermediateDirectories: true
        )
        for filename in ["../outside.wav", "..\\outside.wav", "capture.wav:stream", "", ".", "..", "folder"] {
            let record = DesktopRecordingStore.Record(id: UUID(), audioFilename: filename, modelIdentifier: "test")
            do {
                _ = try await store.audioURL(for: record)
                XCTFail("Accepted unsafe or non-file path: \(filename)")
            } catch { XCTAssertTrue(error is CocoaError) }
        }
    }

    func testExport_CannotOverwriteHistoryFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopRecordingStore(directory: directory)
        var record = DesktopRecordingStore.Record(id: UUID(), audioFilename: "retained.wav", modelIdentifier: "test")
        record.result = TranscriptionResult(
            text: "Keep this recording", segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
        )
        try await store.save(record)
        let metadata = directory.appendingPathComponent(record.id.uuidString + ".json")
        let original = try Data(contentsOf: metadata)
        do {
            try await store.exportTranscript(id: record.id, to: metadata)
            XCTFail("Export overwrote retained metadata")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        XCTAssertEqual(try Data(contentsOf: metadata), original)
    }

    func testLookup_RejectsMismatchedRecordIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopRecordingStore(directory: directory)
        let record = DesktopRecordingStore.Record(id: UUID(), audioFilename: "retained.wav", modelIdentifier: "test")
        let otherID = UUID()
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(otherID.uuidString + ".json"))
        do {
            _ = try await store.record(id: otherID)
            XCTFail("Accepted mismatched record identity")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
    }

    func testPolishedTranscript_PreservesRawResultAndExportsDisplayedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root.appendingPathComponent("History"))
        var record = DesktopRecordingStore.Record(id: UUID(), audioFilename: "recording.wav", modelIdentifier: "test")
        record.result = TranscriptionResult(
            text: "word one", segments: [], confidence: nil, duration: 1,
            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.processedText = "word. one."
        record.postProcessingModelIdentifier = "openai/gpt-5-mini"
        try await store.save(record)
        let saved = try await store.record(id: record.id)
        XCTAssertEqual(saved.result?.text, "word one")
        XCTAssertEqual(saved.displayText, "word. one.")
        XCTAssertEqual(saved.postProcessingModelIdentifier, "openai/gpt-5-mini")
        let export = root.appendingPathComponent("polished.txt")
        try await store.exportTranscript(id: record.id, to: export)
        XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), "word. one.")
    }
}
