import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

/// Windows and Linux move every archive category through the same ZIP as the Mac.
final class DesktopConfigurationTransferTests: XCTestCase {
    func testZIPRoundTrip_RestoresEveryCategoryAndOnlyNamesModels() async throws {
        let source = try RestoreFixture()
        let target = try RestoreFixture()
        defer { source.remove(); target.remove() }
        let seeded = try await TransferFixture.seed(source)
        let zip = try await TransferFixture.export(source, configuration: TransferFixture.fragment(source))
        let host = TransferHost(include: true)
        let targets = target.targets(configuration: host.source)
        let preparation = await DesktopMigrationRestore.prepare(zip, reader: target.reader, targets: targets)
        guard case let .ready(plan) = preparation else { return XCTFail("\(preparation)") }
        let preview = plan.preview
        XCTAssertEqual(
            preview.rows.map(\.category),
            [.settings, .history, .recordings, .credentials, .profiles, .vocabulary, .connections]
        )
        XCTAssertEqual(preview.notApplied, [.models])
        XCTAssertFalse(preview.credentialsDeclined)
        XCTAssertEqual(preview.rows.first { $0.category == .settings }?.conflicts, 1)
        XCTAssertTrue(preview.skipped.contains { $0.contains("download Synthetic Whisper from Local models") })
        XCTAssertTrue(preview.skipped.contains { $0.contains("1 model(s)") && $0.contains("cannot") })
        XCTAssertTrue(preview.skipped.contains { $0.contains("Mac pairing details do not apply") })
        XCTAssertTrue(preview.skipped.contains { $0.contains("1 setting(s) have no equivalent") })
        XCTAssertFalse(preview.text.contains(TransferFixture.secret))
        XCTAssertFalse(host.wrote)

        let outcome = await DesktopMigrationRestore.apply(plan, choice: .merge, targets: targets)
        guard case let .applied(applied) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(applied.history.map(\.processedText), [seeded.processedText])
        XCTAssertEqual(applied.audio, 1)
        XCTAssertTrue(applied.profilesChanged)
        XCTAssertTrue(applied.vocabularyChanged)
        XCTAssertTrue(applied.settingsChanged)
        XCTAssertEqual(applied.credentials, 1)
        let audio = try XCTUnwrap(applied.history.first?.audioFilename)
        let audioURL = target.historyDirectory.appendingPathComponent(audio)
        XCTAssertEqual(try Data(contentsOf: audioURL), TransferFixture.audio)
        XCTAssertEqual(try target.profiles.load().map(\.name), ["Synthetic profile"])
        for definition in DataMigrationVocabularyCatalog.collections {
            let restored = try Data(contentsOf: target.app.appendingPathComponent(definition.desktopPath))
            let expected = try VocabularyMigrationFixtures.data(kind: definition.kind)
            XCTAssertEqual(
                try JSONDecoder().decode([AnyCodable].self, from: restored),
                try JSONDecoder().decode([AnyCodable].self, from: expected)
            )
        }
        XCTAssertEqual(host.preferences["showHUD"], AnyCodable(.bool(true)), "Merge keeps this device's value")
        XCTAssertEqual(host.preferences["enableSendToMac"], AnyCodable(.bool(true)))
        XCTAssertEqual(host.preferences["transcriptionKeywords"], AnyCodable(.string("Synthetic keyword")))
        XCTAssertNil(host.preferences["appearance"])
        XCTAssertEqual(host.credentials, [TransferFixture.credentialID: TransferFixture.secret])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.app.appendingPathComponent("LocalModels").path))
    }

    func testCredentials_StayOutOfExportAndImportWithoutOptIn() async throws {
        let source = try RestoreFixture()
        let target = try RestoreFixture()
        defer { source.remove(); target.remove() }
        _ = try await TransferFixture.seed(source)
        let refusing = DesktopMigrationBackup.Adapter(
            digests: RestoreFixture.digests,
            archive: { try MigrationTestArchive.export($0, digests: RestoreFixture.digests, stagingRoot: source.root) },
            publish: { _, _ in XCTFail("A backup with API keys must not reach a producer without the opt-in.") }
        )
        let destination = source.root.appendingPathComponent("Refused.zip")
        let refused = await DesktopMigrationBackup.export(
            store: source.store, destination: destination,
            contents: .init(includeAudio: false, profiles: nil, configuration: TransferFixture.fragment(source)),
            adapter: refusing
        )
        guard case .failed = refused else { return XCTFail("\(refused)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let withoutKeys = try await TransferFixture.export(source, configuration: TransferFixture.fragment(
            source, credentials: false
        ))
        let unkeyed = try MigrationTestArchive.read(
            withoutKeys, digests: RestoreFixture.digests, stagingRoot: target.root
        )
        XCTAssertFalse(unkeyed.manifest.categories.contains(.credentials))
        XCTAssertNil(unkeyed.records[.credentials])
        try unkeyed.directory.map { try FileManager.default.removeItem(at: $0) }

        let zip = try await TransferFixture.export(source, configuration: TransferFixture.fragment(source))
        let host = TransferHost(include: false)
        let targets = target.targets(configuration: host.source)
        let preparation = await DesktopMigrationRestore.prepare(zip, reader: target.reader, targets: targets)
        guard case let .ready(plan) = preparation else { return XCTFail("\(preparation)") }
        XCTAssertTrue(plan.preview.credentialsDeclined)
        XCTAssertTrue(plan.preview.notApplied.contains(.credentials))
        XCTAssertFalse(plan.preview.rows.contains { $0.category == .credentials })
        XCTAssertEqual(host.credentialReads, 0)
        let outcome = await DesktopMigrationRestore.apply(plan, choice: .replace, targets: targets)
        guard case let .applied(applied) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(applied.credentials, 0)
        XCTAssertTrue(applied.settingsChanged)
        XCTAssertEqual(host.preferences["showHUD"], AnyCodable(.bool(false)), "Replace takes the backup's value")
        XCTAssertEqual(host.credentials, [TransferFixture.credentialID: "existing-synthetic-value"])
        XCTAssertEqual(host.credentialReads, 0)
    }

    func testInvalidArchive_ChangesNothing() async throws {
        let target = try RestoreFixture()
        defer { target.remove() }
        let host = TransferHost(include: true)
        let zip = target.root.appendingPathComponent("Not a backup.zip")
        try Data("Synthetic bytes that are not a ZIP".utf8).write(to: zip)
        let preparation = await DesktopMigrationRestore.prepare(
            zip, reader: target.reader, targets: target.targets(configuration: host.source)
        )
        guard case .failed = preparation else { return XCTFail("\(preparation)") }
        XCTAssertFalse(host.wrote)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.app.path), ["History"])
        let records = try await target.store.records()
        XCTAssertTrue(records.isEmpty)
        let children = try FileManager.default.contentsOfDirectory(atPath: target.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-") })
    }

    func testFailureAfterSettings_RollsBackSettingsKeysVocabularyAudioAndHistory() async throws {
        let source = try RestoreFixture()
        let target = try RestoreFixture()
        defer { source.remove(); target.remove() }
        _ = try await TransferFixture.seed(source)
        let zip = try await TransferFixture.export(source, configuration: TransferFixture.fragment(source))
        let host = TransferHost(include: true)
        let before = (host.preferences, host.credentials)
        let targets = target.targets(configuration: host.source)
        let preparation = await DesktopMigrationRestore.prepare(zip, reader: target.reader, targets: targets)
        guard case let .ready(plan) = preparation else { return XCTFail("\(preparation)") }
        let outcome = await DesktopMigrationRestore.apply(
            plan, choice: .replace, targets: targets,
            checkpoint: { step in if step == .profiles { throw TransferFailure() } }
        )
        guard case let .failed(restored, message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(restored, message)
        XCTAssertTrue(host.wrote)
        XCTAssertEqual(host.undone, 1)
        XCTAssertEqual(host.preferences, before.0)
        XCTAssertEqual(host.credentials, before.1)
        for definition in DataMigrationVocabularyCatalog.collections {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: target.app.appendingPathComponent(definition.desktopPath).path
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.profiles.fileURL.path))
        let records = try await target.store.records()
        XCTAssertTrue(records.isEmpty)
        let audio = try FileManager.default.contentsOfDirectory(atPath: target.historyDirectory.path)
        XCTAssertFalse(audio.contains { $0.hasSuffix(".wav") })
    }
}

private struct TransferFailure: Error {}

private enum TransferFixture {
    static let secret = "SYNTHETIC-NOT-A-REAL-API-KEY"
    static let credentialID = "synthetic.provider.apiKey"
    static let audio = Data([1, 2, 3, 4])

    static func seed(_ fixture: RestoreFixture) async throws -> DesktopRecordingStore.Record {
        let id = UUID()
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: "\(id).wav", modelIdentifier: "synthetic/model", createdAt: RestoreFixture.date
        )
        record.processedText = "Synthetic transferred transcript"
        try audio.write(to: fixture.historyDirectory.appendingPathComponent(record.audioFilename))
        try await fixture.store.save(record)
        try fixture.profiles.save([DictationProfile(name: "Synthetic profile", polishPrompt: nil)])
        for definition in DataMigrationVocabularyCatalog.collections {
            let file = fixture.app.appendingPathComponent(definition.desktopPath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try VocabularyMigrationFixtures.data(kind: definition.kind).write(to: file)
        }
        return record
    }

    static func preference(_ key: String, _ value: AnyCodable.JSONValue) -> DataMigrationRecord {
        DataMigrationRecord(id: key, kind: "default", value: AnyCodable(value))
    }

    static func model(_ id: String) -> DataMigrationRecord {
        DataMigrationRecord(id: id, kind: "modelReference", value: AnyCodable(.object([
            "id": .string(id), "name": .string("Synthetic"), "family": .string("whisper")
        ])))
    }

    static func fragment(_ fixture: RestoreFixture, credentials: Bool = true) -> DesktopMigrationBackup.Configuration {
        .init(
            records: [
                .settings: [preference("showHUD", .bool(false)), preference("appearance", .string("dark"))],
                .connections: [preference("enableSendToMac", .bool(true))],
                .vocabulary: [preference("transcriptionKeywords", .string("Synthetic keyword"))],
                .models: [model("local/synthetic-whisper"), model("local/synthetic-unavailable")]
            ],
            vocabularyDirectory: fixture.app,
            credentials: credentials ? {
                [
                    DataMigrationRecord(id: credentialID, kind: "secret", value: AnyCodable(.string(secret))),
                    preference("speakTransportPairingCode", .string("SYNTHETIC-PAIRING"))
                ]
            } : nil
        )
    }

    static func export(_ fixture: RestoreFixture, configuration: DesktopMigrationBackup.Configuration) async throws
        -> URL {
        let destination = fixture.root.appendingPathComponent("Backup-\(UUID()).zip")
        let root = fixture.root
        let adapter = DesktopMigrationBackup.Adapter(
            digests: RestoreFixture.digests,
            archiveWithCredentials: {
                try MigrationTestArchive.export(
                    $0, digests: RestoreFixture.digests, stagingRoot: root, includeCredentials: $1
                )
            },
            publish: { try FileManager.default.copyItem(at: $0, to: $1) }
        )
        let outcome = await DesktopMigrationBackup.export(
            store: fixture.store, destination: destination,
            contents: .init(includeAudio: true, profiles: fixture.profiles, configuration: configuration),
            adapter: adapter
        )
        XCTAssertEqual(outcome, .saved)
        return destination
    }
}

/// A fake host settings and API-key store. Values are synthetic.
private final class TransferHost: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreferences: [String: AnyCodable] = ["showHUD": AnyCodable(.bool(true))]
    private var storedCredentials = [TransferFixture.credentialID: "existing-synthetic-value"]
    private var writes = 0
    private var undos = 0
    private var reads = 0
    private let include: Bool

    init(include: Bool) {
        self.include = include
        if include { storedCredentials = [:] }
    }

    var preferences: [String: AnyCodable] { lock.withLock { storedPreferences } }
    var credentials: [String: String] { lock.withLock { storedCredentials } }
    var wrote: Bool { lock.withLock { writes > 0 } }
    var undone: Int { lock.withLock { undos } }
    var credentialReads: Int { lock.withLock { reads } }

    var source: DesktopMigrationRestore.ConfigurationSource {
        .init(read: { self.configuration() }, write: { try self.write($0) })
    }

    private func configuration() -> DesktopMigrationRestore.Configuration {
        .init(
            preferences: .init(
                values: preferences, supportedKeys: ["showHUD", "enableSendToMac", "transcriptionKeywords"],
                isValid: { _ in true }
            ),
            credentials: .init(include: include, supported: [TransferFixture.credentialID]) { identifier in
                self.lock.withLock {
                    self.reads += 1
                    return self.storedCredentials[identifier] ?? ""
                }
            },
            models: .init(available: ["local/synthetic-whisper": "Synthetic Whisper"])
        )
    }

    private func write(
        _ change: DesktopMigrationRestore.ConfigurationWrite
    ) throws -> DesktopMigrationRestore.ConfigurationUndo {
        lock.withLock {
            let prior = (storedPreferences, storedCredentials)
            writes += 1
            if let preferences = change.preferences { storedPreferences = preferences }
            for credential in change.credentials { storedCredentials[credential.identifier] = credential.value }
            return {
                self.lock.withLock {
                    self.undos += 1
                    (self.storedPreferences, self.storedCredentials) = prior
                }
            }
        }
    }
}

private extension RestoreFixture {
    var app: URL { root.appendingPathComponent("App", isDirectory: true) }

    var reader: DesktopMigrationInspection.Reader {
        let root = root
        return .init { try MigrationTestArchive.read($0, digests: Self.digests, stagingRoot: root) }
    }

    func targets(configuration: DesktopMigrationRestore.ConfigurationSource) -> DesktopMigrationRestore.Targets {
        .init(history: store, profiles: profiles, digests: Self.digests, configuration: configuration)
    }
}
