import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationInspectionTests: XCTestCase {
    func testRecordChecks_ValidateNativeHistoryAudioAndScopeWithoutDisplayingContents() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.staging()
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let privateText = "SYNTHETIC-TRANSCRIPT-DO-NOT-DISPLAY"
        var native = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "", modelIdentifier: "synthetic/model", createdAt: date
        )
        native.processedText = privateText
        let value = try DesktopMigrationHistory.value(native)
        let valid = DataMigrationRecord(id: native.id.uuidString, kind: "history", value: value, date: date)
        var forged = valid
        forged.id = UUID().uuidString
        let outsideDate = date.addingTimeInterval(10)
        let outsideNative = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "", modelIdentifier: "synthetic/model", createdAt: outsideDate
        )
        let outside = DataMigrationRecord(
            id: outsideNative.id.uuidString, kind: "history",
            value: try DesktopMigrationHistory.value(outsideNative), date: outsideDate
        )
        let brokenCarrier = try malformedCarrier(valid)
        XCTAssertNoThrow(try DataMigrationHistorySchema.validate(brokenCarrier, category: .history))
        let audio = DataMigrationRecord(
            id: native.id.uuidString, kind: "audio",
            value: try DesktopMigrationHistory.value(native, audioOnly: true), date: date
        )
        let snapshot = DataMigrationSnapshot(
            manifest: .init(
                categories: [.history, .recordings], scopes: ["history": .init(end: date.addingTimeInterval(1))]
            ),
            records: [.history: [valid, forged, outside, brokenCarrier], .recordings: [audio]], directory: directory
        )
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in snapshot })
        guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.categories.map(\.items), [4, 1])
        XCTAssertEqual(report.historyChecks.map(\.items), [1, 1])
        XCTAssertEqual(report.invalidHistoryItems, 3)
        XCTAssertEqual(report.noticeCount, 0)
        XCTAssertTrue(report.text.contains("3 History/audio items failed record validation"))
        XCTAssertTrue(report.text.contains("other record values are not validated"))
        XCTAssertFalse(report.text.contains(privateText))
        XCTAssertFalse(report.text.contains(native.id.uuidString))
        XCTAssertFalse(report.text.contains(forged.id))
        XCTAssertFalse(report.text.contains("SYNTHETIC-INVALID-NATIVE-CARRIER"))
        XCTAssertEqual(snapshot.records[.history], [valid, forged, outside, brokenCarrier])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnreadableHistory_IsNotReportedAsZeroStructurallyValidItems() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.staging()
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.history, .recordings], scopes: [:]),
            records: [.recordings: []],
            notices: ["\(DataMigrationCategory.history.title): category could not be read."], directory: directory
        )
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in snapshot })
        guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(report.historyChecks.first?.items)
        XCTAssertEqual(report.historyChecks.last?.items, 0)
        XCTAssertEqual(report.invalidHistoryItems, 0)
        XCTAssertTrue(report.text.contains("\(DataMigrationCategory.history.title): could not be validated"))
        XCTAssertFalse(report.text.contains("\(DataMigrationCategory.history.title): 0 structurally valid"))
    }

}

extension DesktopMigrationInspectionTests {
    func testProfiles_ValidateCanonicalPayloadAndCoverageWithoutDisplayingOrChangingValues() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.staging()
        let profile = DictationProfile(name: "SYNTHETIC-PRIVATE-NAME", polishPrompt: "SYNTHETIC-PRIVATE-PROMPT")
        var valid = DataMigrationRecord(
            id: profile.id.uuidString, kind: DataMigrationProfileCatalog.kind,
            value: try DataMigrationCoding.value(profile)
        )
        guard case var .object(fields) = valid.value.storage else { return XCTFail("Expected profile object.") }
        fields["transcriptionRouting"] = .string("future-routing")
        fields["matchers"] = .array([.object(["kind": .string("future"), "value": .string("private-matcher")])])
        valid.value = AnyCodable(.object(fields))
        var forged = valid
        forged.id = UUID().uuidString
        var outside = valid
        outside.kind = "future-kind"
        var broken = valid
        broken.value = AnyCodable(.string("SYNTHETIC-INVALID-PROFILE"))
        let records = [valid, forged, outside, broken]
        let snapshot = DataMigrationSnapshot(
            manifest: .init(
                categories: [.profiles],
                scopes: ["profiles": .init(selectedIDs: [valid.id], selectedKinds: [DataMigrationProfileCatalog.kind])]
            ),
            records: [.profiles: records], directory: directory
        )
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in snapshot })
        guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.categories.map(\.items), [4])
        XCTAssertEqual(report.profileChecks.map(\.items), [1])
        XCTAssertEqual(report.invalidProfileItems, 3)
        XCTAssertEqual(report.historyChecks, [])
        XCTAssertEqual(report.invalidHistoryItems, 0)
        XCTAssertTrue(report.text.contains("3 profile items failed record validation"))
        for privateValue in [profile.name, profile.polishPrompt ?? "", valid.id, forged.id,
                             "private-matcher", "SYNTHETIC-INVALID-PROFILE"] {
            XCTAssertFalse(report.text.contains(privateValue))
        }
        XCTAssertEqual(snapshot.records[.profiles], records)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testProfiles_MissingAndPresentEmptyRemainDistinct() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let sources: [[DataMigrationCategory: [DataMigrationRecord]]] = [[:], [.profiles: []]]
        for records in sources {
            let snapshot = DataMigrationSnapshot(
                manifest: .init(categories: [.profiles], scopes: [:]),
                records: records, directory: try fixture.staging()
            )
            let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in snapshot })
            guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(report.profileChecks.first?.items, records[.profiles]?.count)
            XCTAssertEqual(report.invalidProfileItems, 0)
            if records[.profiles] == nil {
                XCTAssertTrue(report.text.contains("\(DataMigrationCategory.profiles.title): could not be validated"))
                XCTAssertFalse(report.text.contains("\(DataMigrationCategory.profiles.title): 0 structurally valid"))
            }
        }
    }

    func testProfileZIP_UsesCanonicalValidationAndLeavesOriginalArchiveUnchanged() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let profile = DictationProfile(name: "Synthetic profile", polishPrompt: "SYNTHETIC-PRIVATE-PROMPT")
        let record = DataMigrationRecord(
            id: profile.id.uuidString, kind: DataMigrationProfileCatalog.kind,
            value: try DataMigrationCoding.value(profile)
        )
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.profiles], scopes: [:]), records: [.profiles: [record]]
        )
        let archive = try DesktopMigrationArchive.export(
            snapshot, digests: InspectionFixture.digests, stagingRoot: fixture.root, storage: InspectionFixture.storage
        )
        try FileManager.default.copyItem(at: archive, to: fixture.source)
        let original = try Data(contentsOf: fixture.source)
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: fixture.reader)
        guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.profileChecks.map(\.items), [1])
        XCTAssertEqual(report.invalidProfileItems, 0)
        XCTAssertTrue(report.mergePreview.isEmpty)
        XCTAssertFalse(report.text.contains(profile.polishPrompt ?? ""))
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
    }

}

extension DesktopMigrationInspectionTests {
    func testRealZIP_ReportsCategoriesWithoutDisplayingValuesOrChangingSource() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let secret = "SYNTHETIC-CREDENTIAL-DO-NOT-DISPLAY"
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.credentials, .history, .settings], scopes: [:]),
            records: [
                .settings: [.init(id: "showHUD", kind: "default", value: AnyCodable(.bool(true)))],
                .history: [],
                .credentials: [.init(id: "synthetic.apiKey", kind: "secret", value: AnyCodable(.string(secret)))]
            ]
        )
        let archive = try DesktopMigrationArchive.export(
            snapshot, digests: InspectionFixture.digests, stagingRoot: fixture.root, includeCredentials: true,
            storage: InspectionFixture.storage
        )
        try FileManager.default.copyItem(at: archive, to: fixture.source)
        let expected = try Data(contentsOf: fixture.source)
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: fixture.reader)
        guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.categories.map(\.category), [.settings, .history, .credentials])
        XCTAssertEqual(report.categories.map(\.items), [1, 0, 1])
        XCTAssertEqual(report.noticeCount, 0)
        XCTAssertFalse(report.text.contains(secret))
        XCTAssertFalse(report.text.contains("synthetic.apiKey"))
        XCTAssertTrue(report.text.contains("not displayed or installed"))
        XCTAssertTrue(report.text.contains("Import/apply is not available"))
        XCTAssertEqual(try Data(contentsOf: fixture.source), expected)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix("migration-") && !$0.hasPrefix("migration-export-") })
    }

    func testMissingCategory_IsUnreadableRatherThanSuccessfulEmptyCategory() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.staging()
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.settings, .history], scopes: [:]),
            records: [.history: []],
            notices: ["Settings & shortcuts: category could not be read."], directory: directory
        )
        let outcome = await DesktopMigrationInspection.inspect(
            fixture.source, reader: .init { _ in snapshot }
        )
        guard case let .inspected(report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(report.categories.first?.items)
        XCTAssertEqual(report.categories.last?.items, 0)
        XCTAssertEqual(report.noticeCount, 1)
        XCTAssertTrue(report.text.contains("Settings & shortcuts: could not be read"))
        XCTAssertTrue(report.text.contains("some data may be missing or damaged"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCorruptZIP_FailsWithoutChangingSourceOrLeavingStaging() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let bytes = Data("Synthetic invalid ZIP bytes".utf8)
        try bytes.write(to: fixture.source)
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: fixture.reader)
        guard case let .failed(message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-") })
    }

    func testInvalidReaderOwnership_DoesNotRemoveUnownedDirectory() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("Keep this file")
        let expected = Data("Unowned synthetic bytes".utf8)
        try expected.write(to: marker)
        let snapshot = fixture.snapshot(directory: fixture.root)
        let outcome = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in snapshot })
        guard case let .failed(message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("invalid owned staging path"))
        XCTAssertEqual(try Data(contentsOf: marker), expected)
    }

    func testSourceDirectory_IsNeverAcceptedForCleanupEvenWithAValidStagingName() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.staging()
        let source = directory.appendingPathComponent("Original.zip")
        let expected = Data("Synthetic source".utf8)
        try expected.write(to: source)
        let snapshot = fixture.snapshot(directory: directory)
        let outcome = await DesktopMigrationInspection.inspect(source, reader: .init { _ in snapshot })
        guard case let .failed(message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("source archive's directory"))
        XCTAssertEqual(try Data(contentsOf: source), expected)
    }

    func testCancellationAfterRead_RemovesOwnedStagingAndDoesNotReturnReport() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let directory = try fixture.staging()
        let snapshot = fixture.snapshot(directory: directory)
        let reader = DesktopMigrationInspection.Reader { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return snapshot
        }
        let outcome = await Task.detached {
            await DesktopMigrationInspection.inspect(fixture.source, reader: reader)
        }.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPrecancelledRead_DoesNotCallReader() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let reader = DesktopMigrationInspection.Reader { _ in
            XCTFail("Pre-cancellation must prevent archive I/O.")
            return fixture.snapshot(directory: nil)
        }
        let outcome = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DesktopMigrationInspection.inspect(fixture.source, reader: reader)
        }.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testInvalidSourceURLs_AreRejectedBeforeReader() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        // Encoded construction keeps path normalization from erasing the invalid input.
        let encodedNUL = try XCTUnwrap(URL(
            string: "Archive%00other.zip", relativeTo: fixture.root.appendingPathComponent("", isDirectory: true)
        )).absoluteURL
        XCTAssertTrue(encodedNUL.absoluteString.contains("%00"))
        let sources: [(name: String, url: URL)] = [
            ("remote", try XCTUnwrap(URL(string: "https://example.invalid/backup.zip"))),
            ("directory", fixture.root.appendingPathComponent("Directory", isDirectory: true)),
            ("encoded NUL", encodedNUL)
        ]
        for (name, source) in sources {
            let reader = DesktopMigrationInspection.Reader { _ in
                XCTFail("Invalid \(name) source URLs must never reach the reader.")
                return fixture.snapshot(directory: nil)
            }
            let outcome = await DesktopMigrationInspection.inspect(source, reader: reader)
            guard case .failed = outcome else { return XCTFail("\(name): \(outcome)") }
        }
    }

    func testLiteralPercentZeroFilename_IsNotAnEncodedNUL() throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("Literal%00name.zip")
        XCTAssertTrue(source.absoluteString.contains("%2500"))
        XCTAssertFalse(source.path.contains("\0"))
        XCTAssertNoThrow(try DesktopMigrationStaging.requireLocalFile(source))
    }

    func testMissingReaderStagingAndCleanupFailures_AreExplicitFailures() async throws {
        let fixture = try InspectionFixture()
        defer { fixture.remove() }
        let absent = fixture.snapshot(directory: nil)
        let missing = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in absent })
        guard case let .failed(message) = missing else { return XCTFail("\(missing)") }
        XCTAssertTrue(message.contains("no owned private staging directory"))
        let directory = try fixture.staging()
        let disappeared = fixture.snapshot(directory: directory)
        try FileManager.default.removeItem(at: directory)
        let cleanup = await DesktopMigrationInspection.inspect(fixture.source, reader: .init { _ in disappeared })
        guard case let .failed(detail) = cleanup else { return XCTFail("\(cleanup)") }
        XCTAssertTrue(detail.contains("Private inspection staging could not be removed"))
    }

    private func malformedCarrier(_ source: DataMigrationRecord) throws -> DataMigrationRecord {
        var record = source
        record.id = UUID().uuidString
        let value = try DataMigrationHistoryValue.value(record.value, id: record.id)
        guard case var .object(fields) = value.storage else {
            throw DataMigrationError.invalid("Synthetic fixture must contain History fields.")
        }
        fields["desktopHistory"] = .string("SYNTHETIC-INVALID-NATIVE-CARRIER")
        record.value = AnyCodable(.object(fields))
        return record
    }
}

private struct InspectionFixture: Sendable {
    let root: URL
    var source: URL { root.appendingPathComponent("Chosen backup.zip") }
    static let digests = LocalModelDigestProvider(name: "Synthetic fixed digest; not cryptographic proof") {
        InspectionDigest()
    }
    static let storage = DesktopMigrationArchive.Storage(
        createDirectory: {
            try FileManager.default.createDirectory(
                at: $0, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        },
        createFile: {
            guard FileManager.default.createFile(
                atPath: $0.path, contents: Data(), attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
    )

    var reader: DesktopMigrationInspection.Reader {
        .init { try DesktopMigrationArchive.read(
            $0, digests: Self.digests, stagingRoot: root, storage: Self.storage
        ) }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func staging() throws -> URL {
        let directory = root.appendingPathComponent("migration-\(UUID())", isDirectory: true)
        try Self.storage.createDirectory(directory)
        return directory
    }

    func snapshot(directory: URL?) -> DataMigrationSnapshot {
        .init(manifest: .init(categories: [.history], scopes: [:]), records: [.history: []], directory: directory)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { XCTFail(error.localizedDescription) }
    }
}

private final class InspectionDigest: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws { try Task.checkCancellation() }
    func finish() throws -> String { String(repeating: "a", count: 64) }
}
