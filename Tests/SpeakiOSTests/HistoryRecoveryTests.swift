#if os(iOS)
import Foundation
import XCTest
import UIKit

@testable import SpeakiOSLib

@MainActor
final class HistoryRecoveryTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("history.json")
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func item(_ text: String) -> iOSHistoryItem {
        iOSHistoryItem(transcription: text, model: "test", duration: 1, wordCount: 1)
    }

    private func write(_ items: [iOSHistoryItem], to url: URL? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: url ?? file)
    }

    private func manager(_ storageIO: IOSHistoryPersistence.StorageIO = .init()) -> iOSHistoryManager {
        iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults, storageIO: storageIO)
    }

    func testCorruptPrimaryPreservedAcrossEveryLocalWriterAndRelaunch() throws {
        let original = Data("invalid history".utf8)
        try original.write(to: file)
        let history = manager()
        XCTAssertFalse(history.isStorageReady)
        XCTAssertTrue(history.persistenceError?.contains("decoded") == true)
        let added = item("pending")
        XCTAssertTrue(history.upsertReportingDurability(added))
        history.setPostProcessed("polished", for: added.id)
        history.setError("retry", for: added.id)
        history.remove(added)
        history.clearAll()
        history.flushPendingChanges()
        history.retryPersistence()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(history.items.count, 1)
        let relaunched = manager()
        XCTAssertEqual(relaunched.items.first?.postProcessedTranscription, "polished")
        XCTAssertEqual(relaunched.items.first?.errorMessage, "retry")
        XCTAssertFalse(relaunched.isStorageReady)
    }

    func testTransientAccessFailureMergesExistingAndPendingAfterRelaunch() throws {
        let old = item("old")
        let added = item("new")
        try write([old])
        let original = try Data(contentsOf: file)
        var blocked = true
        let primary = try XCTUnwrap(file)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.read = { url in
            if url == primary && blocked { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        let history = manager(storageIO)
        XCTAssertTrue(history.persistenceError?.contains("unavailable") == true)
        XCTAssertTrue(history.upsertReportingDurability(added))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let relaunched = manager(storageIO)
        XCTAssertEqual(relaunched.items.map(\.id), [added.id])
        blocked = false
        relaunched.retryPersistence()
        relaunched.retryPersistence()
        XCTAssertTrue(relaunched.isStorageReady)
        XCTAssertNil(relaunched.persistenceError)
        XCTAssertEqual(Set(relaunched.items.map(\.id)), [old.id, added.id])
        XCTAssertEqual(manager().items.count, 2)
    }

    func testUnreadableRecoveryCannotBeReplacedAndPendingRemainInMemory() throws {
        try write([item("old")])
        let recovery = file.appendingPathExtension("recovery")
        let original = Data("bad recovery".utf8)
        try original.write(to: recovery)
        let primary = try Data(contentsOf: file)
        let history = manager()
        XCTAssertFalse(history.upsertReportingDurability(item("new")))
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(try Data(contentsOf: recovery), original)
        XCTAssertEqual(try Data(contentsOf: file), primary)
        XCTAssertTrue(history.persistenceError?.contains("only in memory") == true)
    }

    func testBothWritesFailThenRetryPreservesMemoryAndReportsDurabilityTruthfully() throws {
        try write([item("old")])
        var blocked = true
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if blocked { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let history = manager(storageIO)
        let added = item("new")
        XCTAssertFalse(history.upsertReportingDurability(added))
        XCTAssertFalse(history.isStorageReady)
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(manager().items.count, 1)
        blocked = false
        history.retryPersistence()
        XCTAssertTrue(history.isStorageReady)
        XCTAssertTrue(history.upsertReportingDurability(added))
        XCTAssertEqual(manager().items.count, 2)
    }

    func testPrimaryWriteFailureIsDurableInRecoveryAndSurvivesRelaunch() throws {
        try write([item("old")])
        let primary = try XCTUnwrap(file)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if url == primary { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let history = manager(storageIO)
        XCTAssertTrue(history.upsertReportingDurability(item("new")))
        XCTAssertFalse(history.isStorageReady)
        XCTAssertEqual(manager().items.count, 2)
    }

    func testCommitBeforeFailedCleanupReplaysOnceAndRetainsNewestUUIDVersion() throws {
        let old = item("old")
        let newer = old.withPostProcessed("new", updatedAt: old.updatedAt.addingTimeInterval(10))
        try write([newer])
        try write([old], to: file.appendingPathExtension("recovery"))
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        let history = manager(storageIO)
        XCTAssertFalse(history.isStorageReady)
        XCTAssertEqual(history.items.first?.postProcessedTranscription, "new")
        history.clearAll()
        let relaunched = manager()
        relaunched.retryPersistence()
        XCTAssertTrue(relaunched.isStorageReady)
        XCTAssertEqual(relaunched.items.count, 1)
        XCTAssertEqual(relaunched.items.first?.postProcessedTranscription, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("recovery").path))
    }

    func testInaccessibleRecoveryRetainsItsEntriesAndMemoryUntilRetry() throws {
        let old = item("old")
        let pending = item("recovery")
        let added = item("memory")
        try write([old])
        let recovery = file.appendingPathExtension("recovery")
        try write([pending], to: recovery)
        let original = try Data(contentsOf: recovery)
        var blocked = true
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.read = { url in
            if url == recovery && blocked { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        let history = manager(storageIO)
        XCTAssertFalse(history.upsertReportingDurability(added))
        XCTAssertEqual(try Data(contentsOf: recovery), original)
        blocked = false
        history.retryPersistence()
        XCTAssertTrue(history.isStorageReady)
        XCTAssertEqual(Set(manager().items.map(\.id)), [old.id, pending.id, added.id])
    }

    func testFailedDeleteWriteKeepsItemAndAcknowledgement() async throws {
        let old = item("old")
        try write([old])
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let history = manager(storageIO)
        await history.didAcknowledgeSyncedEntries(ids: [old.id])
        history.remove(old)
        history.clearAll()
        XCTAssertEqual(history.items.map(\.id), [old.id])
        XCTAssertTrue(history.isSynced(old))
        XCTAssertEqual(manager().items.map(\.id), [old.id])
    }

    func testInitialFailureWithholdsSyncUntilProtectedDataRetrySucceeds() async throws {
        let existing = item("old")
        try write([existing])
        var blocked = true
        var starts = 0
        let primary = try XCTUnwrap(file)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.read = { url in
            if url == primary && blocked { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        let history = iOSHistoryManager(
            fileURL: file, syncEnabled: true, userDefaults: defaults, storageIO: storageIO,
            startSync: { _ in starts += 1 }
        )
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(starts, 0)
        history.add(item("pending"))
        blocked = false
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(history.isStorageReady)
        XCTAssertEqual(history.pendingEntries().count, 2)
        history.ensureLoaded()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(starts, 1)
    }
}
#endif
