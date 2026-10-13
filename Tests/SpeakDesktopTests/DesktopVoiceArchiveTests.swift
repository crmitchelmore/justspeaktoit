import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopVoiceArchiveTests: XCTestCase {
    func testArchive_CommitsIndependentCanonicalAudioWithoutChangingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        var record = DesktopRecordingStore.Record(id: UUID(), audioFilename: "kept.wav", modelIdentifier: "synthetic")
        record.failure = "Synthetic preserved failure"
        try await store.save(record)
        let metadata = root.appendingPathComponent(record.id.uuidString + ".json")
        let before = try Data(contentsOf: metadata)
        let identifier = UUID()
        let audio = try fixture()
        let archived = try await store.archiveVoiceAudio(audio, identifier: identifier)
        XCTAssertEqual(archived.lastPathComponent, identifier.uuidString + ".wav")
        XCTAssertEqual(try Data(contentsOf: archived), audio.wav)
        let attributes = try FileManager.default.attributesOfItem(atPath: archived.path)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        let records = try await store.records()
        XCTAssertEqual(records.map(\.id), [record.id])
        let recovered = try await store.recoverInterruptedRecordings()
        XCTAssertEqual(recovered.records.map(\.id), [record.id])
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testArchive_CollisionNeverOverwritesAndCleansItsPrivateStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-collision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let identifier = UUID()
        let destination = root.appendingPathComponent(identifier.uuidString + ".wav")
        let original = Data("existing synthetic audio".utf8)
        try original.write(to: destination)
        do {
            _ = try await store.archiveVoiceAudio(fixture(), identifier: identifier)
            XCTFail("An existing destination must be preserved")
        } catch { XCTAssertEqual(try Data(contentsOf: destination), original) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
    }

    func testArchive_CancelledAdmissionCreatesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root)
        let audio = try fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.archiveVoiceAudio(audio)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled archive must be refused")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func fixture() throws -> VoiceGeneratedAudio {
        try VoiceGeneratedAudio(validating: XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data([1, 0, 2, 0]), sampleRate: 24_000
        )))
    }
}
