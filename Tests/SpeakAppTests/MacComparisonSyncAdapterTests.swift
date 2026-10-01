import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class MacComparisonSyncAdapterTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacComparisonSyncAdapterTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "MacComparisonSyncAdapterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testPendingRevisionsSurviveRelaunchAndAcknowledgementIsExact() async throws {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        var round = makeRound(offset: 0)
        store.upsert(round)
        let submitted = try XCTUnwrap(adapter.pendingRevisions().first)
        round.updatedAt = round.updatedAt.addingTimeInterval(0.125)
        round.entries[0].transcript = "newer local edit"
        store.upsert(round)
        try await adapter.acknowledgeRevisions([submitted])
        XCTAssertEqual(adapter.pendingRevisions().first?.round, round)
        let reloaded = ComparisonRoundStore(directory: directory)
        XCTAssertEqual(reloaded.pendingRevisions.first?.round, round)
        try reloaded.acknowledge(reloaded.pendingRevisions)
        XCTAssertTrue(ComparisonRoundStore(directory: directory).pendingRevisions.isEmpty)
    }

    func testDeletionPersistsUntilAcknowledgedAndCannotBeResurrectedByOldUpload() async throws {
        let store = ComparisonRoundStore(directory: directory)
        let round = makeRound(offset: 0)
        store.upsert(round)
        let old = try XCTUnwrap(store.pendingRevisions.first)
        store.remove(id: round.id)
        try store.acknowledge([old])
        let reloaded = ComparisonRoundStore(directory: directory)
        let deletion = try XCTUnwrap(reloaded.pendingRevisions.first)
        XCTAssertNil(deletion.round)
        try reloaded.applyRevision(old)
        XCTAssertNil(reloaded.round(id: round.id))
        XCTAssertEqual(reloaded.pendingRevisions, [deletion])
    }

    func testRemoteRevisionIsAppliedWithoutEchoAndLegacyDeletionPreservesPendingEdit() async throws {
        let store = ComparisonRoundStore(directory: directory)
        let adapter = MacComparisonSyncAdapter(store: store, defaults: defaults)
        var round = makeRound(offset: 0)
        try await adapter.applyRemoteRevision(ModelComparisonRevision(round: round))
        XCTAssertTrue(store.pendingRevisions.isEmpty)
        round.updatedAt = round.updatedAt.addingTimeInterval(1)
        store.upsert(round)
        try await adapter.applyLegacyDeletion(id: round.id)
        XCTAssertEqual(store.round(id: round.id), round)
    }

    func testFailedPersistenceDoesNotAcknowledgeOrPublishRemoteData() async throws {
        let store = ComparisonRoundStore(directory: directory, write: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let revision = ModelComparisonRevision(round: makeRound(offset: 0))
        XCTAssertThrowsError(try store.applyRevision(revision))
        XCTAssertTrue(store.rounds.isEmpty)
        XCTAssertNotNil(store.persistenceError)
    }

    func testDeletingRoundRemovesOwnedRecordingButNotImportedFile() throws {
        let store = ComparisonRoundStore(directory: directory)
        let round = makeRound(offset: 0)
        store.upsert(round)
        let audio = store.samplesDirectory.appendingPathComponent(round.sample.name)
        try Data([1, 2, 3]).write(to: audio)
        store.remove(id: round.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let template = makeRound(offset: 1)
        let imported = ModelComparisonRound(inputMode: .file, sample: template.sample, language: nil,
            originPlatform: "macos", entries: template.entries, blindOrder: template.blindOrder)
        store.upsert(imported)
        try Data([1]).write(to: audio)
        store.remove(id: imported.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    private func makeRound(offset: TimeInterval) -> ModelComparisonRound {
        let entries = ["a", "b"].map {
            ModelComparisonEntry(modelID: $0, modelDisplayName: $0, providerDisplayName: "P", transcript: "t")
        }
        return ModelComparisonRound(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            inputMode: .streaming,
            sample: ModelComparisonSample(name: "s", contentHash: nil, durationSeconds: 1),
            language: nil,
            originPlatform: "macos",
            entries: entries,
            blindOrder: entries.map(\.id)
        )
    }
}
