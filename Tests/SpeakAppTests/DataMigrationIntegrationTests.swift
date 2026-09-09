import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

private final class MigrationTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

@MainActor
final class DataMigrationIntegrationTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let history: HistoryManager
        let store: MigrationStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suite = "migration-test-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            history = HistoryManager(fileManager: MigrationTestFileManager(root: root), flushInterval: 3600,
                                     batchSizeThreshold: 10000)
            store = MigrationStore(
                defaults: defaults,
                support: root.appendingPathComponent("SpeakApp"),
                history: history,
                secrets: SecureStorage(configuration: .init(service: suite))
            )
        }
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func item(id: UUID = UUID(), text: String, audio: URL? = nil) throws -> HistoryItem {
        var object = try XCTUnwrap(HistoryItem.placeholder.migrationValue(audioURL: audio, id: id.uuidString)
            .value as? [String: Any])
        object["rawTranscription"] = text
        object["postProcessedTranscription"] = text
        return try MigrationCoding.decode(HistoryItem.self, AnyCodable(object))
    }
    private func importSnapshot(_ incoming: MigrationSnapshot, into fixture: Fixture,
                                modes: [MigrationCategory: MigrationMode]) async throws {
        let categories = Set(modes.keys)
        let current = try await fixture.store.snapshot(categories: categories.union([.history, .recordings]))
        let validated = fixture.store.validate(incoming)
        XCTAssertTrue(validated.notices.isEmpty, validated.notices.joined(separator: "\n"))
        let plan = MigrationPlanner.plan(current: current, incoming: validated, modes: modes, useImported: [])
        try await fixture.store.apply(plan, categories: categories)
    }
    func testAudioThenText_ReconnectsAndPersistsWithoutDuplicates() async throws {
        let source = try Fixture()
        let destination = try Fixture()
        defer { source.clean(); destination.clean() }
        let audio = source.root.appendingPathComponent("recording.wav")
        let bytes = Data("audio fixture".utf8)
        try bytes.write(to: audio)
        let original = try item(text: "Portable transcript", audio: audio)
        await source.history.append(original)
        let audioExport = try await source.store.snapshot(categories: [.recordings])
        try await importSnapshot(audioExport, into: destination, modes: [.recordings: .merge])
        XCTAssertEqual(destination.history.allItems.count, 1)
        XCTAssertNil(destination.history.allItems[0].rawTranscription)
        let textExport = try await source.store.snapshot(categories: [.history])
        try await importSnapshot(textExport, into: destination, modes: [.history: .merge])
        XCTAssertEqual(destination.history.allItems.count, 1)
        XCTAssertEqual(destination.history.allItems[0].rawTranscription, "Portable transcript")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(destination.history.allItems[0].audioFileURL)), bytes)
        let reloaded = HistoryManager(
            fileManager: MigrationTestFileManager(root: destination.root),
            flushInterval: 3600
        )
        await reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.allItems.count, 1)
        XCTAssertEqual(reloaded.allItems[0].id, original.id)
    }
    func testConflictingHistory_RepeatedImportAfterPersistenceDoesNotDuplicateVariant() async throws {
        let source = try Fixture()
        let destination = try Fixture()
        defer { source.clean(); destination.clean() }
        let id = UUID()
        await source.history.append(try item(id: id, text: "Imported"))
        await destination.history.append(try item(id: id, text: "Existing"))
        let exported = try await source.store.snapshot(categories: [.history])
        try await importSnapshot(exported, into: destination, modes: [.history: .merge])
        try await importSnapshot(exported, into: destination, modes: [.history: .merge])
        XCTAssertEqual(destination.history.allItems.count, 2)
        XCTAssertEqual(
            Set(destination.history.allItems.compactMap(\.rawTranscription)),
            ["Existing", "Imported"]
        )
    }
    func testConflictingText_IdenticalAudioRemainsAttachedToBothVersions() async throws {
        for existingHasAudio in [false, true] {
        let source = try Fixture()
        let destination = try Fixture()
        defer { source.clean(); destination.clean() }
        let audio = source.root.appendingPathComponent("recording.wav")
        try Data("same audio".utf8).write(to: audio)
        let id = UUID()
        await source.history.append(try item(id: id, text: "Imported", audio: audio))
        await destination.history.append(try item(id: id, text: "Existing", audio: existingHasAudio ? audio : nil))
        let exported = try await source.store.snapshot(categories: [.history, .recordings])
        for _ in 0..<2 {
            try await importSnapshot(exported, into: destination, modes: [.history: .merge, .recordings: .merge])
            XCTAssertEqual(destination.history.allItems.count, 2)
            for entry in destination.history.allItems {
                if entry.rawTranscription == "Imported" || existingHasAudio {
                    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(entry.audioFileURL)), Data("same audio".utf8))
                } else {
                    XCTAssertNil(entry.audioFileURL)
                }
            }
        }
        }
    }

    func testExplicitImport_RestoresDeletedHistory() async throws {
        let source = try Fixture()
        defer { source.clean() }
        let original = try item(text: "Restore me")
        await source.history.append(original)
        let exported = try await source.store.snapshot(categories: [.history])
        await source.history.remove(id: original.id)
        try await importSnapshot(exported, into: source, modes: [.history: .merge])
        XCTAssertEqual(source.history.allItems.first?.id, original.id)
    }
    func testRecovery_RestoresSettingsAndKeepsLatestBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.defaults.set("dark", forKey: "appearance")
        let backup = try await fixture.store.snapshot(categories: [.settings])
        let recovery = MigrationRecovery(root: fixture.store.support)
        try recovery.save(backup)
        fixture.defaults.set("light", forKey: "appearance")
        let restored = try recovery.load()
        defer {
            if let directory = restored.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try await importSnapshot(restored, into: fixture, modes: [.settings: .replace])
        XCTAssertEqual(fixture.defaults.string(forKey: "appearance"), "dark")
        XCTAssertTrue(recovery.exists)
        try recovery.save(backup)
        XCTAssertTrue(recovery.exists)
        try recovery.delete()
        XCTAssertFalse(recovery.exists)
    }
    func testRecoveryCredentials_AreEncryptedAndUnlockedByDeviceKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovery = MigrationRecovery(root: root)
        defer { try? recovery.delete(); try? FileManager.default.removeItem(at: root) }
        let record = MigrationRecord(
            id: "test.apiKey",
            kind: "secret",
            value: AnyCodable(.string("synthetic-migration-secret"))
        )
        let snapshot = MigrationSnapshot(manifest: .init(categories: [.credentials], scopes: [:]),
                                         records: [.credentials: [record]])
        try recovery.save(snapshot)
        let readable = try MigrationArchive.read(recovery.directory.appendingPathComponent("recovery.zip"))
        defer {
            if let directory = readable.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertEqual(readable.records[.credentials], [])
        let restored = try recovery.load()
        defer {
            if let directory = restored.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertEqual(restored.records[.credentials], [record])
        let encrypted = try Data(contentsOf: recovery.directory
            .appendingPathComponent("credentials.encrypted"))
        XCTAssertNil(encrypted.range(of: Data("synthetic-migration-secret".utf8)))
    }
    func testSavedAudioWithoutHistory_IsExportedSeparately() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let folder = fixture.root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture.defaults.set(folder.path, forKey: "recordingsDirectory")
        try Data("speech audio".utf8).write(to: folder.appendingPathComponent("speech.wav"))
        let snapshot = try await fixture.store.snapshot(categories: [.history, .recordings])
        XCTAssertEqual(snapshot.records[.history], [])
        XCTAssertEqual(snapshot.records[.recordings]?.count, 1)
    }
    func testVocabularyJSON_RoundTripsPronunciationDictionaryAndProfiles() async throws {
        let source = try Fixture()
        let target = try Fixture()
        defer { source.clean(); target.clean() }
        source.defaults.set(
            try JSONEncoder().encode(["Codex": "code-ex"]),
            forKey: "ttsPronunciationDictionary"
        )
        let export = try await source.store.snapshot(categories: [.vocabulary])
        try await importSnapshot(export, into: target, modes: [.vocabulary: .merge])
        let data = try XCTUnwrap(target.defaults.data(forKey: "ttsPronunciationDictionary"))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: data), ["Codex": "code-ex"])
    }
    func testMigrationLock_QueuesConcurrentHistoryChangesUntilImportFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let initial = try item(text: "Before")
        await fixture.history.append(initial)
        try await fixture.history.beginDataMigration()
        let later = try item(text: "Arrived during import")
        let task = Task { await fixture.history.append(later) }
        await Task.yield()
        XCTAssertEqual(fixture.history.allItems.count, 1)
        try await fixture.history.applyMigrationSnapshot([initial])
        fixture.history.endDataMigration()
        await task.value
        XCTAssertEqual(fixture.history.allItems.count, 2)
        await fixture.history.flushImmediately()
    }

    func testRecordingReplace_RemovesManagedOrphansAfterRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let folder = fixture.store.recordingFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("speech.wav")
        try Data("saved speech".utf8).write(to: audio)
        let previous = try await fixture.store.snapshot(categories: [.history, .recordings])
        let recovery = MigrationRecovery(root: fixture.root)
        try recovery.save(previous)
        defer { try? recovery.delete() }
        let empty = MigrationSnapshot(manifest: .init(categories: [.recordings], scopes: [:]),
                                      records: [.recordings: []])
        try await importSnapshot(empty, into: fixture, modes: [.recordings: .replace])
        XCTAssertEqual(fixture.store.removeReplacedRecordings(previous: previous,
                                                              originalFolder: folder), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let exported = try await fixture.store.snapshot(categories: [.recordings])
        XCTAssertEqual(exported.records[.recordings], [])
        let restored = try recovery.load()
        defer { if let directory = restored.directory { try? FileManager.default.removeItem(at: directory) } }
        XCTAssertEqual(restored.files.count, 1)
    }

}

extension DataMigrationIntegrationTests {
    func testAudioInstallation_VerifiesExistingBytesAndRollsBackNewFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let folder = fixture.root.appendingPathComponent("ImportedRecordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = fixture.root.appendingPathComponent("source.wav")
        let bytes = Data("complete recording".utf8)
        try bytes.write(to: source)
        let existing = folder.appendingPathComponent("existing.wav")
        try Data("partial".utf8).write(to: existing)
        let installation = MigrationAudioInstallation(folder: folder)
        try await installation.install(source: source, destination: existing, digest: MigrationCoding.digest(bytes))
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        let added = folder.appendingPathComponent("new.wav")
        try await installation.install(source: source, destination: added, digest: MigrationCoding.digest(bytes))
        installation.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.path))
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        do {
            try await installation.install(source: source, destination: added, digest: "invalid")
            XCTFail("Expected checksum rejection")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["existing.wav"])
    }

}

extension DataMigrationIntegrationTests {
    func testMigrationSync_OnlyNotifiesNewChangedAndRemovedItems() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let unchanged = try item(text: "Unchanged")
        let edited = try item(text: "Before")
        let removed = try item(text: "Removed")
        for entry in [unchanged, edited, removed] { await fixture.history.append(entry) }
        var uploads: [UUID] = []
        var deletions: [UUID] = []
        fixture.history.onItemAppended = { uploads.append($0.id) }
        fixture.history.onItemRemoved = { deletions.append($0) }
        let changed = try item(id: edited.id, text: "After")
        let added = try item(text: "New")
        let imported = [unchanged, changed, added]
        try await fixture.history.applyMigrationSnapshot(imported)
        XCTAssertEqual(Set(uploads), [changed.id, added.id])
        XCTAssertEqual(deletions, [removed.id])
        uploads.removeAll()
        deletions.removeAll()
        try await fixture.history.applyMigrationSnapshot(imported)
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(deletions.isEmpty)
    }

    func testSettingsReload_RestoresPostProcessingAfterLeavingLivePolish() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let settings = AppSettings(defaults: fixture.defaults)
        settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
        settings.speedMode = .livePolish
        XCTAssertEqual(settings.speedMode, .livePolish)
        fixture.defaults.set("instant", forKey: "speedMode")
        fixture.defaults.set(true, forKey: "postProcessingEnabled")
        settings.reloadAfterMigration()
        XCTAssertEqual(settings.speedMode, .instant)
        XCTAssertTrue(settings.postProcessingEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: "postProcessingEnabled"))
    }

    func testSettingsReload_CoversEveryPublishedPreference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SpeakApp/AppSettings.swift"),
                                encoding: .utf8)
        let pattern = #"@Published\s+(?:private\(set\)\s+)?var\s+(\w+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let names = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            XCTAssertTrue(source.contains("\(name) = restored.\(name)"),
                          "New preference \(name) must participate in migration runtime reload")
        }
    }
    func testNoOpImport_PreservesLocalDiagnosticsAndDoesNotSyncAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var object = try XCTUnwrap(MigrationCoding.value(item(text: "Unchanged")).value as? [String: Any])
        let exchange = HistoryNetworkExchange(url: URL(string: "https://example.com")!, method: "POST",
                                              requestHeaders: [:], requestBodyPreview: "local diagnostics",
                                              responseCode: 200, responseHeaders: [:], responseBodyPreview: "ok")
        object["networkExchanges"] = try MigrationCoding.value([exchange]).value
        let original = try MigrationCoding.decode(HistoryItem.self, AnyCodable(object))
        await fixture.history.append(original)
        let exported = try await fixture.store.snapshot(categories: [.history])
        var uploads = 0
        fixture.history.onItemAppended = { _ in uploads += 1 }
        try await importSnapshot(exported, into: fixture, modes: [.history: .merge])
        XCTAssertEqual(fixture.history.allItems, [original])
        XCTAssertEqual(uploads, 0)
        let moved = try original.replacingMigrationAudio(fixture.root.appendingPathComponent("moved.wav"))
        XCTAssertEqual(moved.networkExchanges, original.networkExchanges)
        XCTAssertEqual(moved.rawTranscription, original.rawTranscription)
    }
}
