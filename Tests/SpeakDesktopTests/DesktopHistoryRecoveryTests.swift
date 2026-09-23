import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// Recovery rewrites WAV headers and metadata at launch, so its inputs are
/// the least trusted files the store ever acts on. Every write must stay on a
/// validated file inside History; everything else is reported and left alone.
final class DesktopHistoryRecoveryTests: XCTestCase {
    private let payload = Data(repeating: 42, count: 6400)
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private var history: URL { root.appendingPathComponent("History") }
    private var sentinel: URL { root.appendingPathComponent("outside.wav") }
    private var interruptedBytes: Data {
        (PCMWaveWriter.wavData(pcm: Data(), sampleRate: 16_000) ?? Data()) + payload
    }
    private let unusableMessage =
        "Recording was interrupted and its audio file is missing or unusable. Retry is unavailable."
    private let recoveredMessage = "Recording was interrupted. Audio recovered for retry."

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try interruptedBytes.write(to: sentinel)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testRecovery_NeverWritesOutsideHistoryOrOverAnotherRecord() async throws {
        let store = try DesktopRecordingStore(directory: history)
        var victim = DesktopRecordingStore.Record(id: UUID(), audioFilename: "victim.wav", modelIdentifier: "test")
        victim.result = TranscriptionResult(
            text: "keep", segments: [], confidence: nil, duration: 1, modelIdentifier: "test",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        try interruptedBytes.write(to: history.appendingPathComponent("victim.wav"))
        try await store.save(victim)
        let victimMetadata = history.appendingPathComponent(victim.id.uuidString + ".json")
        let victimBytes = try Data(contentsOf: victimMetadata)
        let hostileNames = [
            "../outside.wav", sentinel.path, "..\\outside.wav", "outside.wav:stream", "../History/../outside.wav",
            "/", "..", "victim.wav/../../outside.wav"
        ]
        let hostile = try hostileNames.map { try writePending(audioFilename: $0) }
        let impostor = history.appendingPathComponent(UUID().uuidString + ".json")
        try pendingJSON(id: victim.id, audioFilename: "victim.wav").write(to: impostor)
        let impostorBytes = try Data(contentsOf: impostor)

        let report = try await store.recoverInterruptedRecordings()

        XCTAssertEqual(try Data(contentsOf: sentinel), interruptedBytes, "Recovery wrote outside History")
        XCTAssertEqual(try Data(contentsOf: victimMetadata), victimBytes, "Another record's metadata changed")
        XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent("victim.wav")), interruptedBytes)
        XCTAssertEqual(report.unreadableFiles, [impostor.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: impostor), impostorBytes, "Unreadable metadata must be left untouched")
        XCTAssertEqual(report.records.count, hostile.count + 1)
        let kept = try XCTUnwrap(report.records.first { $0.id == victim.id })
        XCTAssertEqual(kept.result?.text, "keep")
        XCTAssertNil(kept.failure)
        for id in hostile {
            let record = try XCTUnwrap(report.records.first { $0.id == id }, "Hostile record \(id) was hidden")
            XCTAssertEqual(record.failure, unusableMessage)
            let saved = try await store.record(id: id)
            XCTAssertEqual(saved.failure, unusableMessage, "The failure must be durable")
            do {
                _ = try await store.audioURL(for: saved)
                XCTFail("Hostile audio name resolved: \(saved.audioFilename)")
            } catch { XCTAssertTrue(error is CocoaError) }
        }
    }

    func testRecovery_RepairsInterruptedAudioAndReportsMissingOrImportedAudio() async throws {
        let store = try DesktopRecordingStore(directory: history)
        let recoverable = try writePending(audioFilename: nil)
        let audio = history.appendingPathComponent(recoverable.uuidString + ".wav")
        try interruptedBytes.write(to: audio)
        let missing = try writePending(audioFilename: nil)
        let imported = try writePending(audioFilename: "imported.mp3")
        try Data([1, 2, 3]).write(to: history.appendingPathComponent("imported.mp3"))

        let report = try await store.recoverInterruptedRecordings()

        XCTAssertEqual(report.unreadableFiles, [])
        XCTAssertEqual(Set(report.records.map(\.id)), [recoverable, missing, imported])
        XCTAssertEqual(try XCTUnwrap(report.records.first { $0.id == recoverable }).failure, recoveredMessage)
        XCTAssertEqual(try Data(contentsOf: audio), PCMWaveWriter.wavData(pcm: payload, sampleRate: 16_000))
        let durable = try await store.record(id: recoverable)
        XCTAssertEqual(durable.failure, recoveredMessage)
        XCTAssertEqual(try XCTUnwrap(report.records.first { $0.id == missing }).failure, unusableMessage)
        let retained = try XCTUnwrap(report.records.first { $0.id == imported })
        XCTAssertEqual(retained.failure, "Transcription was interrupted. Imported audio retained for retry.")
        XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent("imported.mp3")), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: sentinel), interruptedBytes)
        let again = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(again.unreadableFiles, [])
        XCTAssertEqual(Set(again.records.map(\.id)), Set(report.records.map(\.id)), "Recovery is idempotent")
        XCTAssertEqual(try Data(contentsOf: audio), PCMWaveWriter.wavData(pcm: payload, sampleRate: 16_000))
    }

    func testRecovery_RefusesSymlinkedAudioAndMetadata() async throws {
        let store = try DesktopRecordingStore(directory: history)
        let link = history.appendingPathComponent("link.wav")
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        } catch { throw XCTSkip("Symbolic links are unavailable in this environment: \(error)") }
        let linked = try writePending(audioFilename: "link.wav")
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        let foreignID = UUID()
        try pendingJSON(id: foreignID, audioFilename: "link.wav").write(to: elsewhere)
        let foreignBytes = try Data(contentsOf: elsewhere)
        let metadataLink = history.appendingPathComponent(foreignID.uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: metadataLink, withDestinationURL: elsewhere)

        let report = try await store.recoverInterruptedRecordings()

        XCTAssertEqual(try Data(contentsOf: sentinel), interruptedBytes, "Recovery followed a symlink out of History")
        XCTAssertEqual(try Data(contentsOf: elsewhere), foreignBytes, "Recovery wrote through a metadata symlink")
        XCTAssertEqual(report.unreadableFiles, [metadataLink.lastPathComponent])
        XCTAssertEqual(try XCTUnwrap(report.records.first { $0.id == linked }).failure, unusableMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path), "Links are never deleted")
        do {
            _ = try await store.record(id: foreignID)
            XCTFail("A symlinked metadata file was accepted")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        do {
            _ = try await store.records()
            XCTFail("records() accepted a symlinked metadata file")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
    }

    func testMetadataIdentity_IsCheckedTheSameWayEverywhere() async throws {
        let store = try DesktopRecordingStore(directory: history)
        let good = try writePending(audioFilename: nil)
        try interruptedBytes.write(to: history.appendingPathComponent(good.uuidString + ".wav"))
        let lowercase = UUID()
        let lowercaseFile = history.appendingPathComponent(lowercase.uuidString.lowercased() + ".json")
        try pendingJSON(id: lowercase, audioFilename: lowercase.uuidString + ".wav").write(to: lowercaseFile)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: history.path).sorted()
        XCTAssertEqual(DesktopRecordingStore.recordID(ofMetadataFile: lowercaseFile), lowercase)
        XCTAssertNil(DesktopRecordingStore.recordID(ofMetadataFile: history.appendingPathComponent("notes.json")))
        XCTAssertNil(DesktopRecordingStore.recordID(ofMetadataFile: history.appendingPathComponent(good.uuidString)))

        let report = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(report.unreadableFiles, [])
        XCTAssertEqual(Set(report.records.map(\.id)), [good, lowercase])
        XCTAssertEqual(try XCTUnwrap(report.records.first { $0.id == lowercase }).failure, unusableMessage)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: history.path).sorted(), filesBefore,
            "A tolerated basename spelling must be rewritten in place, never duplicated"
        )
        let listed = try await store.records()
        XCTAssertEqual(Set(listed.map(\.id)), [good, lowercase])

        let mismatched = history.appendingPathComponent(UUID().uuidString + ".json")
        try pendingJSON(id: good, audioFilename: good.uuidString + ".wav").write(to: mismatched)
        do {
            _ = try await store.records()
            XCTFail("records() accepted metadata whose identity does not match its basename")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        let report2 = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(report2.unreadableFiles, [mismatched.lastPathComponent])
        let durable = try await store.record(id: good)
        XCTAssertEqual(durable.failure, recoveredMessage)
    }

    /// Writes a pending record (no result, no failure) under its canonical
    /// basename and returns its identifier. A nil audio name uses `<id>.wav`.
    private func writePending(audioFilename: String?) throws -> UUID {
        let id = UUID()
        try pendingJSON(id: id, audioFilename: audioFilename ?? id.uuidString + ".wav")
            .write(to: history.appendingPathComponent(id.uuidString + ".json"))
        return id
    }

    private func pendingJSON(id: UUID, audioFilename: String) throws -> Data {
        let record = DesktopRecordingStore.Record(id: id, audioFilename: "placeholder.wav", modelIdentifier: "test")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        object["audioFilename"] = audioFilename
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
