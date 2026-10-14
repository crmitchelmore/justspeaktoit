import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopNativeConfigurationZIPTests: XCTestCase {
    private typealias Codec = DesktopNativeConfigurationArchiveCodec

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private var digests: LocalModelDigestProvider {
        .init(name: "No audio in native configuration transport") {
            throw DataMigrationError.invalid("Native configuration unexpectedly requested audio hashing.")
        }
    }

    func testActualZIP_RetainsWindowsSourceUnsupportedOnLinuxAndEveryPresenceState() throws {
        let directory = try root()
        let fields = Set(DesktopNativeConfigurationField.allCases.map(\.rawValue))
        let source = try DesktopNativeConfigurationCapture.capture([
            "postProcessing.customPrompt": AnyCodable(.string("  source scope\n\u{00E9}  ")),
            "configuration.postProcessingSystemPrompt": AnyCodable(.string("")),
            "microphoneDeviceID": AnyCodable(.null), "localUseGPU": AnyCodable(.bool(false)),
            "hotKey": AnyCodable(.object([
                "modifiers": .int(0), "virtualKey": .int(0), "style": .string("unknown-to-Linux")
            ]))
        ], platform: .windows, selectedFields: fields)
        let projected = try Codec.project(source)
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.settings], scopes: ["settings": projected.coverage.selectionScope]),
            records: [.settings: projected.records]
        )
        let zip = try MigrationTestArchive.export(snapshot, digests: digests, stagingRoot: directory)
        let read = try MigrationTestArchive.read(zip, digests: digests, stagingRoot: directory)
        XCTAssertTrue(read.notices.isEmpty)
        XCTAssertTrue(read.files.isEmpty)
        XCTAssertEqual(read.records, snapshot.records)
        XCTAssertEqual(read.manifest.scopes, snapshot.manifest.scopes)
        let decoded = try Codec.inspect(XCTUnwrap(read.records[.settings]))
        XCTAssertEqual(decoded.entries, source.entries)
        XCTAssertEqual(decoded.coverage, projected.coverage)
        XCTAssertEqual(decoded.entries.first { $0.field == .hotKey }?.platform, .windows)
        XCTAssertFalse(try XCTUnwrap(read.manifest.scopes["settings"]).isComplete)
    }

    func testActualZIP_ExplicitEmptyReadCoverageStaysEmptyNotFullCategory() throws {
        let directory = try root()
        let projected = try Codec.project(.capture([:], platform: .linux))
        let source = DataMigrationSnapshot(
            manifest: .init(categories: [.settings], scopes: ["settings": projected.coverage.selectionScope]),
            records: [.settings: projected.records]
        )
        let zip = try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        let read = try MigrationTestArchive.read(zip, digests: digests, stagingRoot: directory)
        XCTAssertTrue(read.notices.isEmpty)
        XCTAssertEqual(read.manifest.scopes["settings"]?.selectedIDs, [])
        XCTAssertFalse(try XCTUnwrap(read.manifest.scopes["settings"]).isComplete)
        XCTAssertEqual(try Codec.inspect(XCTUnwrap(read.records[.settings])).coverage.keys, [])
    }

    func testExistingPreferenceImportValidation_StillRejectsTransportKindAndCannotApproveReplacement() throws {
        let capture = try DesktopNativeConfigurationCapture.capture(
            ["postProcessing.customPrompt": AnyCodable(.string("unapplied source prompt"))], platform: .windows,
            selectedFields: ["postProcessing.customPrompt"]
        )
        let projected = try Codec.project(capture)
        for record in projected.records {
            XCTAssertThrowsError(try DataMigrationPreferenceCatalog.validate(record, category: .settings) { _ in
                XCTFail("An unknown native transport reached canonical JSON preference validation.")
            })
        }
        let snapshot = DataMigrationSnapshot(
            manifest: .init(categories: [.settings], scopes: ["settings": projected.coverage.selectionScope]),
            records: [.settings: projected.records]
        )
        let validated = DataMigrationRecordValidation.validate(snapshot) { record, category in
            try DataMigrationPreferenceCatalog.validate(record, category: category) { _ in
                XCTFail("Native transport must remain rejected by existing preference import.")
            }
        }
        XCTAssertEqual(validated.records[.settings], [])
        XCTAssertEqual(validated.notices.count, projected.records.count)
        XCTAssertEqual(validated.manifest.scopes, snapshot.manifest.scopes)
        XCTAssertFalse(projected.coverage.permitsReplacement)
    }
}
