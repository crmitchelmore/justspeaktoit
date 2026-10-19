import Foundation
import SpeakCore
import XCTest

final class DesktopNativeConfigurationCodecTests: XCTestCase {
    private typealias Codec = DesktopNativeConfigurationArchiveCodec
    private typealias Field = DesktopNativeConfigurationField

    private func projection(
        _ sources: [String: AnyCodable] = [:], fields: Set<String> = [Field.customPrompt.rawValue],
        platform: DesktopNativeConfigurationCapture.Platform = .windows
    ) throws -> DesktopNativeConfigurationArchive {
        try Codec.project(.capture(sources, platform: platform, selectedFields: fields))
    }

    private func changing(
        _ record: DataMigrationRecord, key: String, value: AnyCodable.JSONValue?
    ) throws -> DataMigrationRecord {
        guard case .object(var object) = record.value.storage else {
            throw DataMigrationError.invalid("Invalid test fixture.")
        }
        object[key] = value
        var changed = record
        changed.value = AnyCodable(.object(object))
        return changed
    }

    func testPresenceAndDistinctPrompts_RoundTripWithoutDefaultsOrScopeConversion() throws {
        let sources: [String: AnyCodable] = [
            Field.customPrompt.rawValue: AnyCodable(.string("  Native global\nprompt  ")),
            Field.legacyCustomPrompt.rawValue: AnyCodable(.string("")),
            Field.microphoneDeviceID.rawValue: AnyCodable(.null),
            Field.localUseGPU.rawValue: AnyCodable(.bool(false))
        ]
        let fields = Set(Field.allCases.map(\.rawValue))
        let source = try DesktopNativeConfigurationCapture.capture(sources, platform: .windows, selectedFields: fields)
        let projected = try Codec.project(source)
        let decoded = try Codec.decode(Codec.encode(projected))
        XCTAssertEqual(decoded.entries, source.entries)
        XCTAssertEqual(decoded.records, projected.records)
        XCTAssertEqual(decoded.coverage.keys.count, Field.allCases.count)
        XCTAssertFalse(decoded.coverage.selectionScope.isComplete)
        XCTAssertFalse(decoded.coverage.permitsReplacement)
        XCTAssertFalse(decoded.coverage.isCompleteCategory)
        XCTAssertEqual(decoded.entries.first { $0.field == .customPrompt }?.provenance, .nativeSettings)
        XCTAssertEqual(decoded.entries.first { $0.field == .legacyCustomPrompt }?.provenance, .legacyConfiguration)
        let missing = try XCTUnwrap(decoded.entries.first { $0.field == .voiceID })
        XCTAssertFalse(missing.isPresent)
        XCTAssertNil(missing.value)
        let null = try XCTUnwrap(decoded.entries.first { $0.field == .microphoneDeviceID })
        XCTAssertTrue(null.isPresent)
        XCTAssertEqual(null.value, AnyCodable(.null))
    }

    func testEmptySelection_HasExplicitEmptyReadScopeAndNoCredentialPayload() throws {
        let capture = try DesktopNativeConfigurationCapture.capture(
            ["apiKey": AnyCodable(.string("synthetic-excluded-value"))], platform: .linux
        )
        let projected = try Codec.project(capture)
        XCTAssertEqual(projected.unresolvedPaths, ["apiKey"])
        XCTAssertEqual(projected.coverage.keysByKind, [Codec.recordKind: []])
        XCTAssertEqual(projected.coverage.selectionScope.selectedIDs, [])
        XCTAssertFalse(projected.coverage.selectionScope.isComplete)
        let data = try Codec.encode(projected)
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("synthetic-excluded-value"))
        let decoded = try Codec.decode(data)
        XCTAssertTrue(decoded.entries.isEmpty)
        XCTAssertEqual(decoded.coverage, projected.coverage)
    }

    func testStructuredWindowsSource_RetainsZeroAndUnknownTargetValues() throws {
        let hotkey = AnyCodable(.object([
            "modifiers": .int(0), "virtualKey": .int(0), "style": .string("future-source-style")
        ]))
        let output = AnyCodable(.object([
            "method": .string("future-native-method"), "insertion": .string("future-native-insertion"),
            "restoreClipboard": .bool(false)
        ]))
        let source = try projection(
            [Field.hotKey.rawValue: hotkey, Field.textOutput.rawValue: output],
            fields: [Field.hotKey.rawValue, Field.textOutput.rawValue]
        )
        let decoded = try Codec.decode(Codec.encode(source))
        XCTAssertEqual(decoded.records, source.records)
        XCTAssertEqual(decoded.entries.map(\.platform), [.windows, .windows])
        XCTAssertEqual(decoded.entries.first?.value, hotkey)
        XCTAssertThrowsError(try Field.hotKey.validate(hotkey, platform: .linux))
        XCTAssertEqual(decoded.coverage.keys, ["native/windows/hotKey", "native/windows/textOutput"])
    }

    func testBothPlatforms_HaveSeparateDeterministicIdentities() throws {
        let windows = try projection([Field.customPrompt.rawValue: AnyCodable(.string("Windows"))])
        let linux = try projection([Field.customPrompt.rawValue: AnyCodable(.string("Linux"))], platform: .linux)
        let forward = try Codec.inspect(windows.records + linux.records)
        let reverse = try Codec.inspect(linux.records + windows.records)
        XCTAssertEqual(try Codec.encode(forward), try Codec.encode(reverse))
        XCTAssertEqual(forward.entries.map(\.platform), [.linux, .windows])
        XCTAssertEqual(forward.coverage.keys.count, 2)
        XCTAssertThrowsError(try Codec.inspect(windows.records + windows.records))
        XCTAssertThrowsError(try Codec.inspect(windows.records, category: .profiles))
    }

    func testMalformedHeaderAndPresence_FailRatherThanDroppingRecords() throws {
        let record = try XCTUnwrap(projection().records.first)
        let variants: [(String, AnyCodable.JSONValue?)] = [
            ("schemaVersion", .int(2)), ("schemaVersion", .bool(true)),
            ("sourcePlatform", .string("macOS")), ("sourcePath", .string("apiKey")),
            ("sourcePath", .string("postProcessingEnabled")), ("provenance", .string("legacyConfiguration")),
            ("isPresent", .string("false")), ("isPresent", nil),
            ("value", .null), ("unexpected", .bool(false))
        ]
        for (key, value) in variants {
            XCTAssertThrowsError(try Codec.inspect([changing(record, key: key, value: value)]), key)
        }
        XCTAssertThrowsError(try Codec.inspect([changing(record, key: "isPresent", value: .bool(true))]))
        let present = try XCTUnwrap(projection([Field.customPrompt.rawValue: AnyCodable(.null)]).records.first)
        XCTAssertThrowsError(try Codec.inspect([changing(present, key: "value", value: nil)]))
        XCTAssertThrowsError(try Codec.inspect([changing(present, key: "value", value: .bool(false))]))
    }

    func testIdentityKindAndTransportMetadata_RequireExactClosedRecord() throws {
        let original = try XCTUnwrap(projection().records.first)
        for variant in 0..<7 {
            var record = original
            switch variant {
            case 0: record.id = "native/linux/postProcessing.customPrompt"
            case 1: record.kind = "default"
            case 2: record.file = "recordings/unsafe.wav"
            case 3: record.date = Date()
            case 4: record.digest = "synthetic"
            case 5: record.revision = "synthetic"
            default: record.value = AnyCodable(.string("not-an-envelope"))
            }
            XCTAssertThrowsError(try Codec.decode(record))
        }
    }

    func testRawJSON_DuplicateEscapedMembersAndUnknownOuterMembersRefused() throws {
        let record = try XCTUnwrap(projection().records.first)
        let text = try XCTUnwrap(String(data: Codec.encode(projection()), encoding: .utf8))
        for replacement in [
            "\"id\" : \"duplicate\", \"id\"",
            "\"\\u0069d\" : \"duplicate\", \"id\""
        ] {
            let duplicate = text.replacingOccurrences(of: "\"id\"", with: replacement)
            XCTAssertThrowsError(try Codec.decode(Data(duplicate.utf8)))
        }
        let extra = text.replacingOccurrences(of: "\"kind\"", with: "\"unexpected\" : null, \"kind\"")
        XCTAssertThrowsError(try Codec.decode(Data(extra.utf8)))
        let nested = text.replacingOccurrences(
            of: "\"isPresent\"", with: "\"isPresent\" : true, \"\\u0069sPresent\""
        )
        XCTAssertThrowsError(try Codec.decode(Data(nested.utf8)))
        for raw in ["{", "null", "{}", "[true]", "[[]]", "[] trailing"] {
            XCTAssertThrowsError(try Codec.decode(Data(raw.utf8)))
        }
        XCTAssertThrowsError(try Codec.decode(DataMigrationCoding.encoder.encode(record)))
    }

    func testCredentialURLsAndInvalidStructuredTypes_RefusedBySharedMetadata() throws {
        let endpoint = try XCTUnwrap(projection(fields: [Field.azureSpeechResourceEndpoint.rawValue]).records.first)
        let present = try changing(endpoint, key: "isPresent", value: .bool(true))
        for raw in [
            "https://user:password@example.cognitiveservices.azure.com",
            "https://example.cognitiveservices.azure.com?token=synthetic",
            "https://example.cognitiveservices.azure.com#token", "https://unrelated.example.com"
        ] {
            XCTAssertThrowsError(try Codec.decode(changing(present, key: "value", value: .string(raw))))
        }
        let hotkey = try XCTUnwrap(projection(fields: [Field.hotKey.rawValue]).records.first)
        let active = try changing(hotkey, key: "isPresent", value: .bool(true))
        let invalidValues: [AnyCodable.JSONValue] = [
            .object(["style": .string("missing-binding")]),
            .object(["modifiers": .int(-1), "virtualKey": .int(0), "style": .string("raw")]),
            .array([]), .bool(false)
        ]
        for value in invalidValues {
            XCTAssertThrowsError(try Codec.decode(changing(active, key: "value", value: value)))
        }
    }

    func testArchivePolicyBounds_AllowPreviouslyProposedSmallLimitToBeExceeded() throws {
        XCTAssertEqual(Codec.maximumEncodedBytes, DataMigrationArchivePolicy.maximumJSONBytes)
        let prompt = String(repeating: "p", count: 1_048_577)
        let source = try projection([Field.customPrompt.rawValue: AnyCodable(.string(prompt))])
        XCTAssertEqual(try Codec.decode(Codec.encode(source)).entries.first?.value, AnyCodable(.string(prompt)))
    }

    func testArchivePolicyBounds_OversizedDecodeAndEscapedRecordRefused() throws {
        let input = Data(repeating: 32, count: Int(DataMigrationArchivePolicy.maximumJSONBytes) + 1)
        XCTAssertThrowsError(try Codec.decode(input))
        let prompt = String(repeating: "\0", count: Int(DataMigrationArchivePolicy.maximumJSONBytes / 6) + 1)
        let source = try DesktopNativeConfigurationCapture.capture(
            [Field.customPrompt.rawValue: AnyCodable(.string(prompt))], platform: .windows,
            selectedFields: [Field.customPrompt.rawValue]
        )
        XCTAssertThrowsError(try Codec.project(source))
    }

    func testCountAndDepthBounds_ExplicitlyRefuseUnboundedMembers() throws {
        let original = try projection()
        XCTAssertThrowsError(try Codec.inspect(Array(repeating: original.records[0], count: Codec.maximumRecords + 1)))
        var nested = AnyCodable.JSONValue.null
        for _ in 0..<9 { nested = .array([nested]) }
        let deep = try changing(original.records[0], key: "isPresent", value: .bool(true))
        XCTAssertThrowsError(try Codec.decode(changing(deep, key: "value", value: nested)))
        let raw = String(repeating: "[", count: 9) + "null" + String(repeating: "]", count: 9)
        XCTAssertThrowsError(try Codec.decode(Data(raw.utf8)))
    }

    func testAggregateEncodedBound_RefusesOtherwiseValidIndividualRecords() throws {
        let prompt = String(repeating: "\0", count: Int(DataMigrationArchivePolicy.maximumJSONBytes / 12))
        let windows = try projection([Field.customPrompt.rawValue: AnyCodable(.string(prompt))])
        let linux = try projection([Field.customPrompt.rawValue: AnyCodable(.string(prompt))], platform: .linux)
        XCTAssertThrowsError(try Codec.inspect(windows.records + linux.records))
    }

    func testCancellation_PreflightAndDuringLongStringPropagateUnchanged() throws {
        let source = try DesktopNativeConfigurationCapture.capture(
            [Field.customPrompt.rawValue: AnyCodable(.string(String(repeating: "x", count: 100_000)))],
            platform: .windows, selectedFields: [Field.customPrompt.rawValue]
        )
        XCTAssertThrowsError(try Codec.project(source) { throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        var checks = 0
        XCTAssertThrowsError(try Codec.project(source) {
            checks += 1
            if checks == 8 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 8)
        let projected = try Codec.project(source)
        let data = try Codec.encode(projected)
        checks = 0
        XCTAssertThrowsError(try Codec.decode(data) {
            checks += 1
            if checks == 8 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 8)
        XCTAssertThrowsError(try Codec.encode(projected) { throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
