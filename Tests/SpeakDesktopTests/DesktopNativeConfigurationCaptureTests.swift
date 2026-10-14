import SpeakCore
import XCTest

final class DesktopNativeConfigurationCaptureTests: XCTestCase {
    private typealias Field = DesktopNativeConfigurationField

    private func capture(
        _ sources: [String: AnyCodable], fields: [Field],
        platform: DesktopNativeConfigurationCapture.Platform = .windows
    ) throws -> DesktopNativeConfigurationCapture {
        try .capture(sources, platform: platform, selectedFields: Set(fields.map(\.rawValue)))
    }

    func testOptIn_ExcludesKnownAndUnclassifiedValuesByDefault() throws {
        let sources: [String: AnyCodable] = [
            Field.customPrompt.rawValue: AnyCodable(.string("private fixture")),
            "azure.speech.apiKey": AnyCodable(.string("credential fixture")),
            "futureWrapper": AnyCodable(.object(["token": .string("unknown fixture")]))
        ]
        let result = try DesktopNativeConfigurationCapture.capture(sources, platform: .windows)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(Set(result.unresolvedPaths), Set(sources.keys))
        let selected = try capture(sources, fields: [.customPrompt])
        XCTAssertEqual(selected.entries.map(\.sourcePath), [Field.customPrompt.rawValue])
        XCTAssertEqual(selected.unresolvedPaths, ["azure.speech.apiKey", "futureWrapper"])
    }

    func testAbsentEmptyAndFalse_HaveDistinctPresenceAndProvenance() throws {
        let sources: [String: AnyCodable] = [
            Field.customPrompt.rawValue: AnyCodable(.string("")),
            Field.localUseGPU.rawValue: AnyCodable(.bool(false))
        ]
        let result = try capture(sources, fields: [.customPrompt, .legacyCustomPrompt, .localUseGPU])
        let entries = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.field, $0) })
        XCTAssertEqual(entries[.customPrompt]?.value, AnyCodable(.string("")))
        XCTAssertEqual(entries[.customPrompt]?.isPresent, true)
        XCTAssertEqual(entries[.localUseGPU]?.value, AnyCodable(.bool(false)))
        XCTAssertEqual(entries[.legacyCustomPrompt]?.isPresent, false)
        XCTAssertNil(entries[.legacyCustomPrompt]?.value)
        XCTAssertEqual(entries[.customPrompt]?.provenance, .nativeSettings)
        XCTAssertEqual(entries[.legacyCustomPrompt]?.provenance, .legacyConfiguration)
        XCTAssertTrue(result.entries.allSatisfy { $0.platform == .windows })
    }

    func testHotKeyRawObject_PreservesZeroAndUnsupportedStyleWithoutDefaults() throws {
        let value = AnyCodable(.object(["modifiers": .int(0), "virtualKey": .int(0), "style": .string("future")]))
        let result = try capture([Field.hotKey.rawValue: value], fields: [.hotKey])
        XCTAssertEqual(result.entries.first?.value, value)
        let linux = AnyCodable(.object(["style": .string("")]))
        XCTAssertEqual(try capture([Field.hotKey.rawValue: linux], fields: [.hotKey], platform: .linux)
            .entries.first?.value, linux)
    }

    func testTextOutputRawObject_PreservesUnsupportedLabelsAndFalse() throws {
        let windows = AnyCodable(.object([
            "method": .string("future"), "insertion": .string("future"), "restoreClipboard": .bool(false)
        ]))
        let linux = AnyCodable(.object(["method": .string("future"), "restoreClipboard": .bool(false)]))
        XCTAssertEqual(try capture([Field.textOutput.rawValue: windows], fields: [.textOutput]).entries.first?.value,
                       windows)
        XCTAssertEqual(try capture([Field.textOutput.rawValue: linux], fields: [.textOutput], platform: .linux)
            .entries.first?.value, linux)
    }

    func testUnexpectedOrMissingObjectMembersAndInvalidUInt32_FailExplicitly() {
        let cases: [AnyCodable.JSONValue] = [
            .object(["style": .string("future")]),
            .object(["modifiers": .int(0), "virtualKey": .int(0), "style": .string("future"), "apiKey": .string("x")]),
            .object(["modifiers": .int(-1), "virtualKey": .int(0), "style": .string("future")]),
            .object(["modifiers": .int(0), "virtualKey": .double(0.5), "style": .string("future")]),
            .object(["modifiers": .int(0), "virtualKey": .double(.infinity), "style": .string("future")]),
            .object(["modifiers": .int(0), "virtualKey": .double(4_294_967_296), "style": .string("future")])
        ]
        for value in cases {
            XCTAssertThrowsError(try capture([Field.hotKey.rawValue: AnyCodable(value)], fields: [.hotKey]))
        }
        XCTAssertThrowsError(try capture([Field.textOutput.rawValue: AnyCodable(.object([
            "method": .string("paste"), "restoreClipboard": .int(0)
        ]))], fields: [.textOutput], platform: .linux))
    }

    func testUnknownCredentialAndCanonicalSelections_AreNotCaptureKeys() {
        for path in ["azure.speech.apiKey", "futureWrapper", "postProcessingEnabled", "postProcessing",
                     "configuration.values.credentials", "voiceOutput.apiKey"] {
            XCTAssertThrowsError(try DesktopNativeConfigurationCapture.capture(
                [:], platform: .windows, selectedFields: [path]
            ))
        }
        XCTAssertEqual(Set(Field.allCases.map(\.rawValue)).count, Field.allCases.count)
    }

    func testAzureOrigin_PreservesRawTextButRejectsCredentialBearingOrInvalidURLs() throws {
        for endpoint in ["", " \n", " https://MyResource.cognitiveservices.azure.com/ \n", "http://127.0.0.1:8765/"] {
            let value = AnyCodable(.string(endpoint))
            XCTAssertEqual(try capture([Field.azureSpeechResourceEndpoint.rawValue: value],
                                       fields: [.azureSpeechResourceEndpoint]).entries.first?.value, value)
        }
        for endpoint in ["https://user:pass@resource.cognitiveservices.azure.com/",
                         "https://resource.cognitiveservices.azure.com/?key=fixture",
                         "https://resource.cognitiveservices.azure.com/#fixture",
                         "https://unclassified.invalid/", "not a URL"] {
            XCTAssertThrowsError(try capture(
                [Field.azureSpeechResourceEndpoint.rawValue: AnyCodable(.string(endpoint))],
                fields: [.azureSpeechResourceEndpoint]
            ))
        }
    }

    func testInvalidScalar_FailsAndExplicitNullIsNotReportedAsAbsence() throws {
        for value in [AnyCodable.JSONValue.bool(false), .object(["token": .string("fixture")])] {
            XCTAssertThrowsError(try capture([Field.legacyCustomPrompt.rawValue: AnyCodable(value)],
                                             fields: [.legacyCustomPrompt]))
        }
        XCTAssertThrowsError(try capture([Field.voiceTrackUsage.rawValue: AnyCodable(.int(0))],
                                         fields: [.voiceTrackUsage]))
        let null = try capture([Field.legacyCustomPrompt.rawValue: AnyCodable(.null)], fields: [.legacyCustomPrompt])
        XCTAssertEqual(null.entries.first?.isPresent, true)
        XCTAssertEqual(null.entries.first?.value, AnyCodable(.null))
    }
}
