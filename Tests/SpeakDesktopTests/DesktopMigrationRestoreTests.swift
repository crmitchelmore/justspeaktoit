import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationRestoreTests: XCTestCase {
    func testPrepare_PreviewsWithoutWritingAndKeepsSecretsOut() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let existing = DictationProfile(name: "Existing", polishPrompt: nil)
        try fixture.profiles.save([existing])
        let profileBytes = try Data(contentsOf: fixture.profiles.fileURL)
        let incomingProfile = DictationProfile(name: "SYNTHETIC-PROFILE-NAME", polishPrompt: "SYNTHETIC-PROMPT")
        let history = try RestoreFixture.history(UUID(), text: "SYNTHETIC-TRANSCRIPT")
        let secret = DataMigrationRecord(
            id: "synthetic", kind: "credential", value: AnyCodable(.string("SECRET-VALUE"))
        )
        let staging = try fixture.staging()
        var snapshot = RestoreFixture.snapshot(
            [.history: [history], .profiles: [try RestoreFixture.profile(incomingProfile)], .credentials: [secret]],
            categories: [.settings, .history, .credentials, .profiles]
        )
        snapshot.directory = staging
        let preparation = await DesktopMigrationRestore.prepare(
            fixture.source, reader: .init { _ in snapshot }, targets: fixture.targets
        )
        guard case let .ready(plan) = preparation else { return XCTFail("\(preparation)") }
        let preview = plan.preview
        XCTAssertEqual(preview.rows.map(\.category), [.history, .profiles])
        XCTAssertEqual(preview.rows.first?.merge?.added, 1)
        XCTAssertEqual(preview.rows.last?.merge?.added, 1)
        XCTAssertEqual(preview.rows.last?.replace?.removed, 1)
        XCTAssertTrue(preview.offersReplace)
        XCTAssertEqual(preview.notApplied, [.settings, .credentials])
        let text = preview.text
        XCTAssertTrue(text.contains("Nothing has been written yet"))
        XCTAssertTrue(text.contains(DataMigrationCategory.credentials.title + ": never imported automatically"))
        for privateValue in ["SECRET-VALUE", "SYNTHETIC-TRANSCRIPT", "SYNTHETIC-PROFILE-NAME", "SYNTHETIC-PROMPT",
                             history.id, incomingProfile.id.uuidString] {
            XCTAssertFalse(text.contains(privateValue), privateValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: fixture.profiles.fileURL), profileBytes)
        let records = try await fixture.store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testReplace_KeepsExistingProfilesWhenCategoryIsMissingOrDamaged() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let existing = DictationProfile(name: "Existing", polishPrompt: nil)
        try fixture.profiles.save([existing])
        let incoming = try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))
        let damaged = "\(DataMigrationCategory.profiles.title): some items could not be read."
        let sources = [
            RestoreFixture.snapshot([:], categories: [.profiles]),
            RestoreFixture.snapshot([.profiles: [incoming]], categories: [.profiles], notices: [damaged])
        ]
        for snapshot in sources {
            let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
            let outcome = await DesktopMigrationRestore.apply(plan, choice: .replace, targets: fixture.targets)
            guard case .applied = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(try fixture.profiles.load().contains { $0.id == existing.id })
        }
        let missing = try await DesktopMigrationRestore.plan(sources[0], targets: fixture.targets)
        XCTAssertNil(missing.preview.rows.first?.merge)
        XCTAssertFalse(missing.preview.offersReplace)
        XCTAssertTrue(missing.preview.text.contains("could not be read, so existing items are kept"))
    }

    func testReplace_MakesIntactProfilesMatchWhileMergeKeepsExisting() async throws {
        for choice in [DesktopMigrationRestore.Choice.merge, .replace] {
            let fixture = try RestoreFixture()
            defer { fixture.remove() }
            let existing = DictationProfile(name: "Existing", polishPrompt: nil)
            let incoming = DictationProfile(name: "Incoming", polishPrompt: nil)
            try fixture.profiles.save([existing])
            let snapshot = RestoreFixture.snapshot([.profiles: [try RestoreFixture.profile(incoming)]])
            let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
            let outcome = await DesktopMigrationRestore.apply(plan, choice: choice, targets: fixture.targets)
            guard case let .applied(applied) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(applied.profilesChanged)
            let expected = choice == .merge ? [existing.id, incoming.id] : [incoming.id]
            XCTAssertEqual(try fixture.profiles.load().map(\.id), expected)
        }
    }

    func testHistoryConflict_IsMaterialisedAsNewLocalItemWithoutSyncedOrigin() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let id = UUID()
        try await fixture.store.save(RestoreFixture.native(id, text: "This device"))
        let snapshot = RestoreFixture.snapshot([.history: [try RestoreFixture.history(id, text: "Backup")]])
        let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
        XCTAssertEqual(plan.preview.rows.first?.merge?.added, 1)
        XCTAssertEqual(plan.preview.rows.first?.merge?.updated, 0)
        let outcome = await DesktopMigrationRestore.apply(plan, choice: .merge, targets: fixture.targets)
        guard case let .applied(applied) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(applied.history.count, 1)
        let restored = try XCTUnwrap(applied.history.first)
        XCTAssertNotEqual(restored.id, id)
        XCTAssertEqual(restored.processedText, "Backup")
        XCTAssertNil(restored.originPlatform)
        XCTAssertFalse(restored.isSyncedCopy)
        XCTAssertNotNil(restored.migrationMetadata)
        let stored = try await fixture.store.record(id: restored.id)
        XCTAssertEqual(stored.processedText, "Backup")
        XCTAssertNil(stored.originPlatform)
        let original = try await fixture.store.record(id: id)
        XCTAssertEqual(original.processedText, "This device")
    }

    func testFailureDuringHistory_RollsBackEveryWrittenFileAndProfiles() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let existingID = UUID()
        try await fixture.store.save(RestoreFixture.native(existingID, text: nil))
        let existingFile = fixture.historyFile(existingID)
        let existingBytes = try Data(contentsOf: existingFile)
        let added = [UUID(), UUID()]
        let snapshot = RestoreFixture.snapshot([
            .history: try [existingID, added[0], added[1]].map { try RestoreFixture.history($0, text: "Restored") },
            .profiles: [try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))]
        ])
        let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
        XCTAssertEqual(plan.preview.rows.first?.merge?.updated, 1)
        XCTAssertEqual(plan.preview.rows.first?.merge?.added, 2)
        let outcome = await DesktopMigrationRestore.apply(
            plan, choice: .merge, targets: fixture.targets,
            checkpoint: { step in if step == .history(2) { throw InjectedFailure() } }
        )
        guard case let .failed(restored, message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(restored)
        XCTAssertTrue(message.contains("Everything was put back"))
        XCTAssertEqual(try Data(contentsOf: existingFile), existingBytes)
        for id in added {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(id).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profiles.fileURL.path))
        let records = try await fixture.store.records()
        XCTAssertEqual(records.map(\.id), [existingID])
    }

    func testCancellationBeforeProfiles_WritesNothing() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        try fixture.profiles.save([DictationProfile(name: "Existing", polishPrompt: nil)])
        let profileBytes = try Data(contentsOf: fixture.profiles.fileURL)
        let snapshot = RestoreFixture.snapshot([
            .history: [try RestoreFixture.history(UUID(), text: "Restored")],
            .profiles: [try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))]
        ])
        let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
        let outcome = await DesktopMigrationRestore.apply(
            plan, choice: .replace, targets: fixture.targets,
            checkpoint: { step in if step == .profiles { throw CancellationError() } }
        )
        guard case let .cancelled(restored, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(restored)
        XCTAssertEqual(try Data(contentsOf: fixture.profiles.fileURL), profileBytes)
        let records = try await fixture.store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testChangedHistoryAfterPreview_IsRefusedWithoutWriting() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let incoming = UUID()
        let snapshot = RestoreFixture.snapshot([.history: [try RestoreFixture.history(incoming, text: "Restored")]])
        let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
        let local = UUID()
        try await fixture.store.save(RestoreFixture.native(local, text: "Recorded after preview"))
        let outcome = await DesktopMigrationRestore.apply(plan, choice: .merge, targets: fixture.targets)
        guard case .stale = outcome else { return XCTFail("\(outcome)") }
        let records = try await fixture.store.records()
        XCTAssertEqual(records.map(\.id), [local])
    }

    func testDeletedAndSyncedHistory_AreNeverRestoredOrOverwritten() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let deleted = UUID()
        try await fixture.store.save(RestoreFixture.native(deleted, text: "Deleted here"))
        try await fixture.store.delete(id: deleted, deleteAudio: false)
        let synced = UUID()
        try await fixture.store.save(.init(
            syncedID: synced, createdAt: RestoreFixture.date, modelIdentifier: "synthetic/model",
            originPlatform: "macos"
        ))
        let snapshot = RestoreFixture.snapshot([.history: [
            try RestoreFixture.history(deleted, text: "Backup"), try RestoreFixture.history(synced, text: "Backup")
        ]])
        let plan = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
        XCTAssertFalse(plan.preview.changes(.merge))
        XCTAssertTrue(plan.preview.skipped.contains { $0.contains("deleted on this device") })
        XCTAssertTrue(plan.preview.skipped.contains { $0.contains("synced from another device") })
        let outcome = await DesktopMigrationRestore.apply(plan, choice: .merge, targets: fixture.targets)
        guard case let .applied(applied) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(applied.history.isEmpty)
        let isDeleted = await fixture.store.isDeleted(id: deleted)
        XCTAssertTrue(isDeleted)
        let kept = try await fixture.store.record(id: synced)
        XCTAssertEqual(kept.originPlatform, "macos")
        XCTAssertNil(kept.processedText)
    }

    func testDuplicateHistoryIdentitiesDifferingOnlyByCase_AreRefused() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let id = UUID()
        var lower = try RestoreFixture.history(id, text: "One")
        lower.id = id.uuidString.lowercased()
        lower.value = try DataMigrationHistoryValue.value(lower.value, id: lower.id)
        let snapshot = RestoreFixture.snapshot(
            [.history: [try RestoreFixture.history(id, text: "Two"), lower]]
        )
        do {
            _ = try await DesktopMigrationRestore.plan(snapshot, targets: fixture.targets)
            XCTFail("Duplicate identities must not reach apply.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("duplicate identities"))
        }
        let records = try await fixture.store.records()
        XCTAssertTrue(records.isEmpty)
    }
}

private struct InjectedFailure: Error {}

struct RestoreFixture {
    static let date = Date(timeIntervalSince1970: 1_704_067_200)
    static let digests = LocalModelDigestProvider(name: "Synthetic test digest; not cryptographic") {
        RestoreDigest()
    }

    let root: URL
    let store: DesktopRecordingStore
    let profiles: DesktopDictationProfileStore
    let historyDirectory: URL
    var source: URL { root.appendingPathComponent("Chosen backup.zip") }
    var targets: DesktopMigrationRestore.Targets { .init(history: store, profiles: profiles, digests: Self.digests) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = root.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        historyDirectory = app.appendingPathComponent("History", isDirectory: true)
        store = try DesktopRecordingStore(directory: historyDirectory)
        profiles = DesktopDictationProfileStore(directory: app)
    }

    func historyFile(_ id: UUID) -> URL { historyDirectory.appendingPathComponent(id.uuidString + ".json") }

    func staging() throws -> URL {
        let directory = root.appendingPathComponent("migration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { XCTFail(error.localizedDescription) }
    }

    static func native(_ id: UUID, text: String?) -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: "", modelIdentifier: "synthetic/model", createdAt: date
        )
        record.processedText = text
        return record
    }

    static func history(_ id: UUID, text: String?) throws -> DataMigrationRecord {
        DataMigrationRecord(
            id: id.uuidString, kind: "history", value: try DesktopMigrationHistory.value(native(id, text: text)),
            date: date
        )
    }

    static func profile(_ profile: DictationProfile) throws -> DataMigrationRecord {
        DataMigrationRecord(
            id: profile.id.uuidString, kind: DataMigrationProfileCatalog.kind,
            value: try DataMigrationCoding.value(profile)
        )
    }

    static func snapshot(
        _ records: [DataMigrationCategory: [DataMigrationRecord]], categories: [DataMigrationCategory]? = nil,
        notices: [String] = []
    ) -> DataMigrationSnapshot {
        DataMigrationSnapshot(
            manifest: .init(
                categories: categories ?? DataMigrationCategory.allCases.filter { records[$0] != nil }, scopes: [:]
            ),
            records: records, notices: notices
        )
    }
}

/// Deterministic, collision-resistant enough for fixtures; not cryptographic.
private final class RestoreDigest: LocalModelSHA256Hasher {
    private var lanes: [UInt64] = [
        0xcbf2_9ce4_8422_2325, 0x8422_2325_cbf2_9ce4, 0x9e37_79b9_7f4a_7c15, 0x2545_f491_4f6c_dd1d
    ]

    func update(_ bytes: UnsafeRawBufferPointer) throws {
        for byte in bytes {
            for index in lanes.indices {
                lanes[index] = (lanes[index] ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 &+ UInt64(index + 1)
            }
        }
    }

    func finish() throws -> String {
        lanes.map { lane in
            let hex = String(lane, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }
}
