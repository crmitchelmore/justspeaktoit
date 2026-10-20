import Foundation
import XCTest
@testable import SpeakCore

final class DesktopNativeSourceDocumentTests: XCTestCase {
    private typealias Codec = DesktopNativeSourceDocumentCodec

    private func projection(_ data: Data?, platform: DesktopNativeSourceDocument.Platform = .windows) throws
        -> DesktopNativeSourceDocument.Projection {
        let source = try Codec.capture(
            platform: platform, source: .desktopVocabularyPreferences, rawBytes: data, allowSensitiveContent: true
        )
        return try Codec.project([source], allowSensitiveContent: true)
    }

    private func changed(
        _ record: DataMigrationRecord, key: String, value: AnyCodable.JSONValue?
    ) throws -> DataMigrationRecord {
        guard case .object(var body) = record.value.storage else { throw TestError.invalid }
        body[key] = value
        var result = record
        result.value = AnyCodable(.object(body))
        return result
    }

    func testOpaqueBytes_RetainBOMWhitespaceUnknownDuplicatesAndMalformedEvidenceWithoutAuthority() throws {
        for data in [Data(), Data([0xFF, 0, 0xFE]), Data("malformed".utf8),
                     Data([0xEF, 0xBB, 0xBF]) + Data(#" {"unknown":1,"unknown":2} "#.utf8),
                     Data([0xFF, 0xFE, 0x7B, 0, 0x7D, 0]), Data([0xFF, 0xFE, 0, 0, 0x7B, 0, 0, 0])] {
            let source = try projection(data)
            let restored = try Codec.decode(Codec.encode(source, allowSensitiveContent: true),
                                            allowSensitiveContent: true)
            XCTAssertEqual(restored.evidence.first?.rawBytes, data)
            XCTAssertFalse(restored.isCompleteCategory)
            XCTAssertFalse(restored.hasApplyOrBackupAuthority)
            XCTAssertFalse(restored.evidence[0].hasApplyOrBackupAuthority)
            XCTAssertFalse(restored.scope.isComplete)
            XCTAssertEqual(restored.scope.selectedIDs, ["native-source/windows/vocabulary.json"])
        }
    }

    func testAbsenceVersusPresentEmpty_HasStrictDistinctEnvelopesWithoutDefaults() throws {
        let absent = try projection(nil)
        let empty = try projection(Data())
        XCTAssertNotEqual(absent.records, empty.records)
        let missing = try Codec.decode(Codec.encode(absent, allowSensitiveContent: true), allowSensitiveContent: true)
        let present = try Codec.decode(Codec.encode(empty, allowSensitiveContent: true), allowSensitiveContent: true)
        XCTAssertNil(missing.evidence[0].rawBytes)
        XCTAssertEqual(present.evidence[0].rawBytes, Data())
        XCTAssertEqual(try Codec.project([], allowSensitiveContent: true).scope.selectedIDs, [])
    }

    func testAllOperations_RequireExplicitSensitiveContentOptIn() throws {
        XCTAssertThrowsError(try Codec.capture(
            platform: .windows, source: .desktopVocabularyPreferences, rawBytes: nil
        ))
        let source = try projection(Data("synthetic opaque user text".utf8))
        let data = try Codec.encode(source, allowSensitiveContent: true)
        XCTAssertThrowsError(try Codec.project(source.evidence))
        XCTAssertThrowsError(try Codec.encode(source))
        XCTAssertThrowsError(try Codec.decode(data))
        XCTAssertThrowsError(try Codec.decode(source.records[0]))
    }

    func testClosedPlatforms_DeterministicIdentitiesDuplicatesAndMacRejection() throws {
        let windows = try projection(nil)
        let linux = try projection(Data(), platform: .linux)
        let forward = try Codec.project(windows.evidence + linux.evidence, allowSensitiveContent: true)
        let reverse = try Codec.project(linux.evidence + windows.evidence, allowSensitiveContent: true)
        XCTAssertEqual(try Codec.encode(forward, allowSensitiveContent: true),
                       try Codec.encode(reverse, allowSensitiveContent: true))
        XCTAssertEqual(forward.evidence.map(\.platform), [.linux, .windows])
        XCTAssertThrowsError(try Codec.project(windows.evidence + windows.evidence, allowSensitiveContent: true))
        XCTAssertThrowsError(try DataMigrationVocabularyCatalog.validate(windows.records[0], category: .vocabulary))
        XCTAssertThrowsError(try Codec.decode(windows.records[0], category: .settings, allowSensitiveContent: true))
    }

    func testStrictHeaders_PresenceTypesUnknownMembersPathsPlatformsAndBase64Refused() throws {
        let source = try projection(Data([1]))
        let record = source.records[0]
        let changes: [(String, AnyCodable.JSONValue?)] = [
            ("schemaVersion", .bool(true)), ("schemaVersion", .int(2)),
            ("sourcePlatform", .string("macOS")), ("sourceRoot", .string("external")),
            ("sourcePath", .string("../vocabulary.json")), ("sourcePath", .string("Vocabulary.json")),
            ("provenance", .string("nativeSettings")), ("isPresent", .string("true")),
            ("isPresent", .bool(false)), ("rawBytes", nil), ("rawBytes", .null),
            ("rawBytes", .string("AR==")), ("rawBytes", .string("AQ==\n")),
            ("rawEncoding", .string("utf8")), ("unexpected", .bool(false))
        ]
        for (key, value) in changes {
            XCTAssertThrowsError(try Codec.decode(changed(record, key: key, value: value), allowSensitiveContent: true))
        }
        let absent = try projection(nil).records[0]
        XCTAssertThrowsError(try Codec.decode(
            changed(absent, key: "rawEncoding", value: .string("base64")), allowSensitiveContent: true
        ))
    }

    func testRawEnvelope_DuplicatesEscapedDuplicatesAndMalformedTrailingInputRefused() throws {
        let text = try XCTUnwrap(String(
            data: Codec.encode(projection(Data()), allowSensitiveContent: true), encoding: .utf8
        ))
        for replacement in [#""id":"duplicate","id""#, #""\u0069d":"duplicate","id""#] {
            let invalid = text.replacingOccurrences(of: "\"id\"", with: replacement)
            XCTAssertThrowsError(try Codec.decode(Data(invalid.utf8), allowSensitiveContent: true))
        }
        let nested = text.replacingOccurrences(of: "\"isPresent\"", with: #""isPresent":true,"\u0069sPresent""#)
        XCTAssertThrowsError(try Codec.decode(Data(nested.utf8), allowSensitiveContent: true))
        for raw in ["{", "null", "{}", "[true]", "[[]]", "[] trailing"] {
            XCTAssertThrowsError(try Codec.decode(Data(raw.utf8), allowSensitiveContent: true))
        }
        let outer = text.replacingOccurrences(of: "\"kind\"", with: #""date":null,"kind""#)
        XCTAssertThrowsError(try Codec.decode(Data(outer.utf8), allowSensitiveContent: true))
    }

    func testTransportMetadata_AndWrongRecordIdentitiesRefused() throws {
        let original = try projection(nil).records[0]
        for variant in 0..<6 {
            var record = original
            switch variant {
            case 0: record.id = "native-source/linux/vocabulary.json"
            case 1: record.kind = "nativeConfiguration"
            case 2: record.file = "vocabulary.json"
            case 3: record.date = Date()
            case 4: record.digest = "synthetic"
            default: record.revision = "synthetic"
            }
            XCTAssertThrowsError(try Codec.decode(record, allowSensitiveContent: true))
        }
    }

    func testTypedEnvelope_RefusesUnknownNonJSONValuesBeforeEncoding() throws {
        let record = try changed(projection(nil).records[0], key: "unexpected", value: .double(.nan))
        XCTAssertThrowsError(try Codec.decode(record, allowSensitiveContent: true)) {
            XCTAssertEqual($0.localizedDescription, "Invalid or unbounded native source document envelope.")
        }
    }

    func testCombinedRawAndBase64EnvelopeBudget_ExactBoundaryAndAggregateCheckedWithoutLargeAllocation() throws {
        let maximum = Codec.maximumBytes
        try Codec.admitSizes([3], encodedHeaderBytes: maximum - 7)
        XCTAssertThrowsError(try Codec.admitSizes([3], encodedHeaderBytes: maximum - 6))
        try Codec.admitSizes([1, 2], encodedHeaderBytes: maximum - 11)
        XCTAssertThrowsError(try Codec.admitSizes([1, 2], encodedHeaderBytes: maximum - 10))
        XCTAssertThrowsError(try Codec.admitSizes([UInt64.max], encodedHeaderBytes: 0))
        let source = try projection(Data(repeating: 0xAA, count: 1_048_577))
        XCTAssertEqual(try Codec.decode(Codec.encode(source, allowSensitiveContent: true),
                                       allowSensitiveContent: true).evidence, source.evidence)
    }

    func testCancellation_PreflightAndLongBase64TokenPropagateWithoutContentDiagnostics() throws {
        let source = try projection(Data(repeating: 0xAA, count: 100_000))
        let data = try Codec.encode(source, allowSensitiveContent: true)
        XCTAssertThrowsError(try Codec.decode(data, allowSensitiveContent: true, checkCancellation: {
            throw CancellationError()
        })) { XCTAssertTrue($0 is CancellationError) }
        var checks = 0
        XCTAssertThrowsError(try Codec.decode(data, allowSensitiveContent: true, checkCancellation: {
            checks += 1
            if checks == 8 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 8)
        XCTAssertThrowsError(try Codec.decode(Data(#"{"sensitive-marker":null}"#.utf8), allowSensitiveContent: true)) {
            XCTAssertFalse($0.localizedDescription.contains("sensitive-marker"))
        }
    }

    private enum TestError: Error { case invalid }
}
