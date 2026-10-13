import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopComparisonLifecycleTests: XCTestCase {
    func testDeleteCommitsTombstoneBeforeRemovingOnlyOwnedSampleAndRelaunchKeepsDeletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopComparisonStore(directory: directory)
        let round = round()
        try await store.upsert(round)
        let sample = try sampleFile(directory: directory, id: round.id)
        let original = directory.appendingPathComponent("original.wav")
        try Data([1, 2]).write(to: original)
        try await store.remove(id: round.id, at: round.updatedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.path))
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2]))
        let relaunched = try DesktopComparisonStore(directory: directory)
        let rounds = await relaunched.rounds()
        let pending = await relaunched.pendingRevisions()
        XCTAssertTrue(rounds.isEmpty)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending[0].round)
        XCTAssertGreaterThan(pending[0].updatedAt, round.updatedAt)
    }

    func testFailedDeletionCommitKeepsRoundAndAudio() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopComparisonStore(directory: directory)
        let round = round()
        try await store.upsert(round)
        let sample = try sampleFile(directory: directory, id: round.id)
        let failing = try DesktopComparisonStore(directory: directory) { _, _ in
            throw DesktopComparisonError.message("Synthetic durable-write failure")
        }
        do {
            try await failing.remove(id: round.id)
            XCTFail("Expected write failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("durable-write")) }
        let rounds = await failing.rounds()
        XCTAssertEqual(rounds, [round])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
    }

    func testOrphanPruningKeepsReferencedAudioAndUnrecognizedFilesWithoutAgeLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopComparisonStore(directory: directory)
        let round = round()
        try await store.upsert(round)
        let kept = try sampleFile(directory: directory, id: round.id)
        let orphan = try sampleFile(directory: directory, id: UUID())
        let unrelated = kept.deletingLastPathComponent().appendingPathComponent("not-owned.wav")
        try Data([3, 4]).write(to: unrelated)
        try await store.pruneOrphanSamples()
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([3, 4]))
    }

    func testAcknowledgementCannotClearNewerLocalChangesAndDeletionWinsAtEqualRevisionTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DesktopComparisonStore(directory: directory)
        var round = round()
        try await store.upsert(round)
        let submitted = ModelComparisonRevision(round: round)
        round.updatedAt = round.updatedAt.addingTimeInterval(1)
        try await store.upsert(round)
        try await store.acknowledgeRevisions([submitted])
        let pending = await store.pendingRevisions()
        XCTAssertEqual(pending, [ModelComparisonRevision(round: round)])
        let deletion = ModelComparisonRevision(deleting: round.id, at: round.updatedAt)
        try await store.applyRemoteRevision(deletion)
        try await store.applyRemoteRevision(ModelComparisonRevision(round: round))
        let rounds = await store.rounds()
        let afterRemote = await store.pendingRevisions()
        XCTAssertTrue(rounds.isEmpty)
        XCTAssertTrue(afterRemote.isEmpty)
    }

    func testComparisonCaptureSafetyLimitIsTenMinutesNotAnAudioRetentionPolicy() {
        XCTAssertEqual(DesktopComparisonLive.maximumCaptureDuration, .seconds(600))
    }

    private func round() -> ModelComparisonRound {
        let entries = ["first", "second"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "Synthetic")
        }
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1000), inputMode: .streaming,
            sample: .init(name: "sample.wav", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "synthetic", entries: entries, blindOrder: entries.map(\.id)
        )
    }

    private func sampleFile(directory: URL, id: UUID) throws -> URL {
        let samples = directory.appendingPathComponent("Samples")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let file = samples.appendingPathComponent(id.uuidString + ".wav")
        try Data([1, 2]).write(to: file)
        return file
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
