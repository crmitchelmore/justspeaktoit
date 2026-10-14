import Foundation
import SpeakCore
import SpeakDesktop
import SpeakLinuxPlatform
import SpeakTestSupport
import XCTest

final class LinuxMigrationArchiveTests: XCTestCase {
    func testHistoryCollector_RoundTripsRealStoreThroughNativeGLibArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try DesktopRecordingStore(directory: directory)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "captured.wav", modelIdentifier: "openai/whisper-1",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200.625)
        )
        record.recordedDuration = 2.5
        record.processedText = "Synthetic native History"
        try MigrationArchiveFixtures.audio.write(to: directory.appendingPathComponent(record.audioFilename))
        try await store.save(record)
        let source = try await store.migrationSnapshot(categories: [.history, .recordings],
                                                       digests: LinuxSHA256Hasher.provider)
        let file = try LinuxMigrationArchive.export(source, digests: LinuxSHA256Hasher.provider)
        addTeardownBlock { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try LinuxMigrationArchive.read(file, digests: LinuxSHA256Hasher.provider)
        let staging = try XCTUnwrap(result.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: staging) }
        XCTAssertEqual(result.records, source.records)
        let history = try XCTUnwrap(result.records[.history]?.first)
        let restored = try DesktopMigrationHistory.record(history, category: .history, audioFilename: "installed.wav")
        XCTAssertEqual(restored.createdAt, record.createdAt)
        XCTAssertEqual(try DesktopMigrationHistory.value(restored), history.value)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files.values.first)), MigrationArchiveFixtures.audio)
    }

    func testArchiveExport_StreamsNativeGLibVerifiedAudioIntoReadableZIP64() throws {
        let source = try LinuxMigrationArchive.read(
            MigrationArchiveFixtures.url("long-unicode"), digests: LinuxSHA256Hasher.provider
        )
        let sourceDirectory = try XCTUnwrap(source.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: sourceDirectory) }
        let file = try LinuxMigrationArchive.export(source, digests: LinuxSHA256Hasher.provider)
        addTeardownBlock { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try LinuxMigrationArchive.read(file, digests: LinuxSHA256Hasher.provider)
        let resultDirectory = try XCTUnwrap(result.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: resultDirectory) }
        XCTAssertEqual(result.records, source.records)
        XCTAssertTrue(result.notices.isEmpty)
        for audio in result.files.values { XCTAssertEqual(try Data(contentsOf: audio), MigrationArchiveFixtures.audio) }
    }

    func testMigrationPlanner_UsesNativeGLibForMacCompatibleVariantIdentifiers() throws {
        let original = DataMigrationRecord(id: "session", kind: "history", value: AnyCodable(.string("Original")))
        let changed = DataMigrationRecord(
            id: "session", kind: "history", value: AnyCodable(.string("Changed")), revision: "changed"
        )
        let manifest = DataMigrationManifest(categories: [.history], scopes: [:])
        let result = try DesktopMigrationPlanner.plan(
            current: .init(manifest: manifest, records: [.history: [original]]),
            incoming: .init(manifest: manifest, records: [.history: [changed]]),
            modes: [.history: .merge], useImported: [], digests: LinuxSHA256Hasher.provider
        )
        XCTAssertEqual(result.records[.history]?.map(\.id), ["session", MigrationPlannerFixtures.changedID])
    }

    func testArchiveAudio_UsesNativeGLibVerificationAndGeneratedStaging() throws {
        let result = try LinuxMigrationArchive.read(
            MigrationArchiveFixtures.url("zip64"), digests: LinuxSHA256Hasher.provider
        )
        let directory = try XCTUnwrap(result.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(result.files["recordings/test.wav"])
        XCTAssertEqual(try Data(contentsOf: file), MigrationArchiveFixtures.audio)
        XCTAssertTrue(result.notices.isEmpty)
    }
}
