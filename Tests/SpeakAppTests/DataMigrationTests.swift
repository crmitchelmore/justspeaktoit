import Foundation
import Security
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class DataMigrationTests: XCTestCase {
    private func snapshot(_ category: MigrationCategory, _ records: [MigrationRecord],
                          scope: MigrationScope = .init()) -> MigrationSnapshot {
        .init(
            manifest: .init(categories: [category], scopes: [category.rawValue: scope]),
            records: [category: records]
        )
    }
    private func text(
        _ id: String = UUID().uuidString,
        value: String = "Hello",
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> MigrationRecord {
        .init(id: id, kind: "history", value: AnyCodable(.string(value)), date: date, revision: value)
    }
    func testMergeHistory_SkipsDuplicatesAndPreservesDifferentVersionsIdempotently() {
        let first = text()
        var changed = first
        changed.value = AnyCodable(.string("Changed"))
        changed.revision = "changed"
        let current = snapshot(.history, [first])
        XCTAssertEqual(MigrationPlanner.plan(current: current, incoming: current,
                                             modes: [.history: .merge],
                                             useImported: []).records[.history]?.count, 1)
        let incoming = snapshot(.history, [changed])
        let merged = MigrationPlanner.plan(current: current, incoming: incoming,
                                           modes: [.history: .merge], useImported: [])
        XCTAssertEqual(merged.records[.history]?.count, 2)
        XCTAssertNotEqual(merged.records[.history]?[0].id, merged.records[.history]?[1].id)
        XCTAssertEqual(MigrationPlanner.plan(current: merged, incoming: incoming,
                                             modes: [.history: .merge],
                                             useImported: []).records[.history]?.count, 2)
    }
    func testReplaceDateRange_PreservesOutsideRange() {
        let outside = text(date: Date(timeIntervalSince1970: 1))
        let inside = text(date: Date(timeIntervalSince1970: 100))
        let replacement = text(date: Date(timeIntervalSince1970: 101))
        let incoming = snapshot(.history, [replacement], scope: .init(start: Date(timeIntervalSince1970: 50),
                                                                      end: Date(timeIntervalSince1970: 150)))
        let plan = MigrationPlanner.plan(current: snapshot(.history, [outside, inside]), incoming: incoming,
                                         modes: [.history: .replace], useImported: [])
        XCTAssertEqual(Set(plan.records[.history, default: []].map(\.id)), [outside.id, replacement.id])
    }
    func testSelectedReplacement_RespectsExplicitSelectionEvenWhenEmpty() {
        let old = text()
        let other = text()
        let incoming = snapshot(.history, [], scope: .init(selectedIDs: [old.id]))
        let plan = MigrationPlanner.plan(current: snapshot(.history, [old, other]), incoming: incoming,
                                         modes: [.history: .replace], useImported: [])
        XCTAssertEqual(plan.records[.history], [other])
    }
    func testInvalidItems_DoNotCauseReplacementDataLoss() {
        let old = text()
        var incoming = snapshot(.history, [])
        incoming.notices = ["History text & speech usage, item 1: skipped invalid item."]
        let plan = MigrationPlanner.plan(current: snapshot(.history, [old]), incoming: incoming,
                                         modes: [.history: .replace], useImported: [])
        XCTAssertEqual(plan.records[.history], [old])
    }
    func testConfigurationMerge_RequiresExplicitConflictChoice() {
        let old = MigrationRecord(id: "appearance", kind: "default", value: AnyCodable(.string("light")))
        var changed = old
        changed.value = AnyCodable(.string("dark"))
        let current = snapshot(.settings, [old])
        let incoming = snapshot(.settings, [changed])
        let conflicts = MigrationPlanner.conflicts(
            current: current,
            incoming: incoming,
            modes: [.settings: .merge]
        )
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(MigrationPlanner.plan(current: current, incoming: incoming,
                                             modes: [.settings: .merge],
                                             useImported: []).records[.settings], [old])
        XCTAssertEqual(MigrationPlanner.plan(current: current, incoming: incoming,
                                             modes: [.settings: .merge],
                                             useImported: [conflicts[0].id]).records[.settings], [changed])
    }
    func testValidation_RejectsUnknownOrWrongTypePreferencesAndCrossCategoryCredentials() throws {
        XCTAssertThrowsError(try MigrationCatalog.validate(
            .init(id: "speakDeviceId", kind: "default",
                  value: AnyCodable(.string("copied-device"))),
            category: .settings
        ))
        XCTAssertThrowsError(try MigrationCatalog.validate(
            .init(id: "runAtLogin", kind: "default",
                  value: AnyCodable(.string("yes"))),
            category: .settings
        ))
        XCTAssertThrowsError(try MigrationCatalog.validate(.init(id: "openai.apiKey", kind: "secret",
                                                                 value: AnyCodable(
                                                                     .string("synthetic-test-key")
                                                                 )), category: .settings))
        XCTAssertNoThrow(try MigrationCatalog.validate(
            .init(id: "runAtLogin", kind: "default",
                  value: AnyCodable(.bool(true))),
            category: .settings
        ))
    }
    func testDefaultExport_ExcludesAllCredentials() {
        XCTAssertFalse(MigrationCategory.defaults.contains(.credentials))
        XCTAssertEqual(MigrationCatalog.category(for: "speakTransportPairingCode"), .credentials)
        XCTAssertEqual(MigrationCatalog.category(for: "speakTransportPairedDevices"), .credentials)
    }
    func testArchive_RoundTripsReadableJSONAndRecordingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        let bytes = Data("synthetic audio fixture".utf8)
        try bytes.write(to: audio)
        var record = text()
        record.kind = "audio"
        record.file = "recordings/test.wav"
        record.digest = MigrationCoding.digest(bytes)
        var source = snapshot(.recordings, [record])
        source.files[record.file!] = audio
        let archive = root.appendingPathComponent("export.zip")
        try MigrationArchive.write(source, to: archive)
        let restored = try MigrationArchive.read(archive)
        defer {
            if let directory = restored.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertEqual(restored.records[.recordings], [record])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.files[record.file!])), bytes)
        XCTAssertTrue(restored.notices.isEmpty)
    }
    func testArchive_RepeatedRecordingPathDoesNotMaterialiseExtraFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        let bytes = Data("shared bytes".utf8)
        try bytes.write(to: audio)
        var record = text()
        record.kind = "audio"
        record.file = "recordings/shared.wav"
        record.digest = MigrationCoding.digest(bytes)
        var other = record
        other.id = UUID().uuidString
        var source = snapshot(.recordings, [record, other])
        source.files[record.file!] = audio
        let archive = root.appendingPathComponent("export.zip")
        try MigrationArchive.write(source, to: archive)
        let restored = try MigrationArchive.read(archive)
        let directory = try XCTUnwrap(restored.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(restored.records[.recordings]?.count, 1)
        XCTAssertEqual(restored.notices.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testArchive_CorruptRecordingIsSkippedAndReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try Data("fixture".utf8).write(to: audio)
        var record = text()
        record.kind = "audio"
        record.file = "recordings/test.wav"
        record.digest = "invalid"
        var source = snapshot(.recordings, [record])
        source.files[record.file!] = audio
        let archive = root.appendingPathComponent("export.zip")
        try MigrationArchive.write(source, to: archive)
        let restored = try MigrationArchive.read(archive)
        defer {
            if let directory = restored.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertTrue(restored.records[.recordings, default: []].isEmpty)
        XCTAssertEqual(restored.notices.count, 1)
    }
    func testArchivePaths_RejectTraversalAbsoluteAndNestedPaths() {
        for path in [
            "../a.wav",
            "/recordings/a.wav",
            "recordings/../a.wav",
            "recordings/..\\a.wav",
            "recordings/a/b.wav", "recordings/run.command", "recordings/code.dylib"
        ] {
            XCTAssertFalse(MigrationArchive.safeAudioPath(path))
        }
        XCTAssertTrue(MigrationArchive.safeAudioPath("recordings/a.wav"))
    }
    func testEmptyCategory_RoundTripsAsPresentSoRecoveryCanClearIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("empty.zip")
        try MigrationArchive.write(snapshot(.history, []), to: url)
        let result = try MigrationArchive.read(url)
        defer {
            if let directory = result.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertEqual(result.records[.history], [])
    }
    func testArchive_OverwritesDestinationUsingReplacementStorageOnItsVolume() throws {
        let parent = ProcessInfo.processInfo.environment["MIGRATION_TEST_VOLUME"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("export.zip")
        try MigrationArchive.write(snapshot(.history, [text(value: "Before")]), to: destination)
        let updated = text(value: "After")
        try MigrationArchive.write(snapshot(.history, [updated]), to: destination)
        let restored = try MigrationArchive.read(destination)
        defer { if let directory = restored.directory { try? FileManager.default.removeItem(at: directory) } }
        XCTAssertEqual(restored.records[.history], [updated])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["export.zip"])
    }
}
