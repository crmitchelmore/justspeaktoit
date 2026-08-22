import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

/// FileManager that redirects Application Support to a temporary directory so
/// `HistoryManager` persists to an isolated location during tests.
private final class TemporaryApplicationSupportFileManager: FileManager {
    let supportURL: URL

    init(supportURL: URL) {
        self.supportURL = supportURL
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        return [supportURL]
    }
}

/// Startup persistence failure safety (issue #695): a load failure must never
/// let a partial in-memory view replace the on-disk history, WAL append
/// failures must be surfaced, and recovery must keep both the original
/// history and mutations queued while storage was unavailable.
@MainActor
final class HistoryPersistenceFailureTests: XCTestCase {
    private var tempDir: URL!
    private var fileManager: TemporaryApplicationSupportFileManager!

    private var historyDir: URL {
        tempDir
            .appendingPathComponent("SpeakApp", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    private var walURL: URL {
        historyDir.appendingPathComponent("history-wal.json", isDirectory: false)
    }

    private var storageURL: URL {
        historyDir.appendingPathComponent("history-log.json", isDirectory: false)
    }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileManager = TemporaryApplicationSupportFileManager(supportURL: tempDir)
    }

    override func tearDown() async throws {
        try? setPermissions(0o700, at: historyDir)
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        fileManager = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeManager() async -> HistoryManager {
        let manager = HistoryManager(
            fileManager: fileManager,
            flushInterval: 3600,
            batchSizeThreshold: 10_000
        )
        await manager.waitUntilLoaded()
        return manager
    }

    private func makeCoder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    private func makeItem(createdAt: Date = Date()) -> HistoryItem {
        HistoryItem(
            id: UUID(),
            createdAt: createdAt,
            modelsUsed: ["apple/local/SFSpeechRecognizer"],
            rawTranscription: "raw transcript",
            postProcessedTranscription: nil,
            recordingDuration: 10,
            cost: nil,
            audioFileURL: nil,
            networkExchanges: [],
            events: [],
            phaseTimestamps: PhaseTimestamps(
                recordingStarted: nil,
                recordingEnded: nil,
                transcriptionStarted: nil,
                transcriptionEnded: nil,
                postProcessingStarted: nil,
                postProcessingEnded: nil,
                outputDelivered: nil
            ),
            trigger: HistoryTrigger(
                gesture: .singleTap,
                hotKeyDescription: "Fn",
                outputMethod: .clipboard,
                destinationApplication: nil
            ),
            personalCorrections: nil,
            errors: []
        )
    }

    private func setPermissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    func testUnreadableWAL_failsStartupAndNeverAltersEitherFile() async throws {
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let (encoder, _) = makeCoder()
        let existing = [makeItem(createdAt: Date().addingTimeInterval(-20)), makeItem()]
        try encoder.encode(existing).write(to: storageURL, options: [.atomic])
        var walData = try encoder.encode(WALEntry(operation: .append, item: makeItem()))
        walData.append(0x0A)
        try walData.write(to: walURL, options: [.atomic])
        let snapshotBytes = try Data(contentsOf: storageURL)
        try setPermissions(0o000, at: walURL)
        defer { try? setPermissions(0o644, at: walURL) }

        let manager = await makeManager()
        guard case .failed = manager.loadState else {
            return XCTFail("Expected failed load state, got \(manager.loadState)")
        }
        XCTAssertNotNil(manager.persistenceError)

        // Attempted mutations while failed must not touch either file.
        await manager.append(makeItem())
        await manager.flushImmediately()

        try setPermissions(0o644, at: walURL)
        XCTAssertEqual(try Data(contentsOf: storageURL), snapshotBytes)
        XCTAssertEqual(try Data(contentsOf: walURL), walData)
    }

    func testRetryAfterStorageBecomesReadable_keepsHistoryAndQueuedAppend() async throws {
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let (encoder, decoder) = makeCoder()
        let original = makeItem(createdAt: Date().addingTimeInterval(-20))
        try encoder.encode([original]).write(to: storageURL, options: [.atomic])
        let walItem = makeItem(createdAt: Date().addingTimeInterval(-10))
        var walData = try encoder.encode(WALEntry(operation: .append, item: walItem))
        walData.append(0x0A)
        try walData.write(to: walURL, options: [.atomic])
        try setPermissions(0o000, at: walURL)
        defer { try? setPermissions(0o644, at: walURL) }

        let manager = await makeManager()
        guard case .failed = manager.loadState else {
            return XCTFail("Expected failed load state")
        }
        let queued = makeItem()
        await manager.append(queued)

        try setPermissions(0o644, at: walURL)
        await manager.retryLoad()

        XCTAssertTrue(manager.loadState.isReady)
        XCTAssertEqual(
            Set(manager.allItems.map(\.id)),
            Set([original.id, walItem.id, queued.id]),
            "original history, replayed WAL entry and the queued append must all survive"
        )

        await manager.flushImmediately()
        XCTAssertNil(manager.persistenceError)
        let persisted = try decoder.decode([HistoryItem].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(Set(persisted.map(\.id)), Set([original.id, walItem.id, queued.id]))
    }

    func testUnreadableSnapshot_failsStartupWithoutInventingEmptyHistory() async throws {
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let (encoder, _) = makeCoder()
        try encoder.encode([makeItem()]).write(to: storageURL, options: [.atomic])
        try setPermissions(0o000, at: storageURL)
        defer { try? setPermissions(0o644, at: storageURL) }

        let manager = await makeManager()
        guard case .failed = manager.loadState else {
            return XCTFail("Expected failed load state")
        }
        XCTAssertTrue(manager.allItems.isEmpty)
    }

    func testFullyUndecodableWAL_isQuarantinedAndSnapshotStillLoads() async throws {
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let (encoder, _) = makeCoder()
        let existing = makeItem()
        try encoder.encode([existing]).write(to: storageURL, options: [.atomic])
        let garbage = Data("not json at all\nstill not json\n".utf8)
        try garbage.write(to: walURL, options: [.atomic])

        let manager = await makeManager()

        XCTAssertTrue(manager.loadState.isReady)
        XCTAssertEqual(manager.allItems.map(\.id), [existing.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: historyDir.path)
            .filter { $0.hasPrefix("history-wal.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
        let quarantineURL = historyDir.appendingPathComponent(quarantined[0])
        XCTAssertEqual(try Data(contentsOf: quarantineURL), garbage)
    }

    func testWALAppendFailure_surfacesErrorAndFlushMakesItDurable() async throws {
        let manager = await makeManager()
        XCTAssertTrue(manager.loadState.isReady)

        // Make the directory unwritable so the WAL append cannot create its file.
        try setPermissions(0o500, at: historyDir)
        let item = makeItem()
        await manager.append(item)
        XCTAssertNotNil(manager.persistenceError, "a failed WAL append must be surfaced, not logged as success")

        // Once the store is writable again, the periodic flush path makes the
        // mutation durable and clears the surfaced error.
        try setPermissions(0o700, at: historyDir)
        await manager.flushImmediately()
        XCTAssertNil(manager.persistenceError)

        let (_, decoder) = makeCoder()
        let persisted = try decoder.decode([HistoryItem].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(persisted.map(\.id), [item.id])
    }

}
