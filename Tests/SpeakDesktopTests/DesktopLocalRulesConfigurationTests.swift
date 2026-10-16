import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLocalRulesConfigurationTests: XCTestCase {
    private let rules = LocalPostProcessingModel.builtInRulesModelID
    private let model = ApplicationPreferenceKey.postProcessingModel.rawValue
    private let enabled = ApplicationPreferenceKey.postProcessingEnabled.rawValue
    private let prompt = DesktopPostProcessingConfiguration.customPromptKey

    func testLocalImportExportIsExecutableAndRemovesRuntimeMirrors() throws {
        for flag in [false, true] {
            let source = try DesktopConfiguration(values: [
                model: AnyCodable(.string(rules)), enabled: AnyCodable(.bool(flag)),
                prompt: AnyCodable(.string("Retain remote instructions.")),
                ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue: AnyCodable(.bool(false)),
                ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue: AnyCodable(.bool(true)),
                "future": AnyCodable(.array([.int(42)]))
            ])
            var options: DesktopPostProcessing.Options?
            let retained = try DesktopPostProcessingConfiguration.importOptions(from: source, into: &options)
            XCTAssertEqual(options?.mode, flag ? .local : .disabled)
            XCTAssertEqual(options?.modelIdentifier, rules)
            XCTAssertEqual(options?.customPrompt, "Retain remote instructions.")
            XCTAssertEqual(options?.includeLexiconDirectives, false)
            XCTAssertEqual(options?.includeContextTags, true)
            XCTAssertTrue(DesktopPostProcessingConfiguration.keys.isDisjoint(with: retained.values.keys))
            let exported = try DesktopPostProcessingConfiguration.exportOptions(options, over: retained)
            XCTAssertEqual(exported, source)
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(exported)
            )
            var restarted: DesktopPostProcessing.Options?
            _ = try DesktopPostProcessingConfiguration.importOptions(from: restored, into: &restarted)
            XCTAssertEqual(restarted, options)
        }
    }

    func testImportRequiresStrictBooleanAndTextTypesBeforeChangingOptions() throws {
        let original = DesktopPostProcessing.Options(customPrompt: "Keep.")
        let invalid: [[String: AnyCodable]] = [
            [enabled: AnyCodable(.string("true"))], [enabled: AnyCodable(.int(1))],
            [enabled: AnyCodable(.null)], [model: AnyCodable(.bool(true))],
            [ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue: AnyCodable(.int(0))],
            [ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue: AnyCodable(.string("false"))],
            [prompt: AnyCodable(.array([]))], [prompt: AnyCodable(.string("bad\0prompt"))]
        ]
        for values in invalid {
            var options: DesktopPostProcessing.Options? = original
            XCTAssertThrowsError(try DesktopPostProcessingConfiguration.importOptions(
                from: DesktopConfiguration(values: values), into: &options
            ))
            XCTAssertEqual(options, original)
        }
    }

    func testUnsupportedLocalValuesStayDisabledAndRoundTripWithoutRemoteSubstitution() throws {
        for identifier in ["local/post-processing/downloaded", "LOCAL/post-processing/unknown",
                           AppleLocalModels.foundationModelID] {
            let source = try DesktopConfiguration(values: [
                model: AnyCodable(.string(identifier)), enabled: AnyCodable(.bool(true)),
                prompt: AnyCodable(.string("Keep custom instructions.")),
                ApplicationPreferenceKey.postProcessingIncludeLexiconDirectives.rawValue: AnyCodable(.bool(true)),
                ApplicationPreferenceKey.postProcessingIncludeContextTags.rawValue: AnyCodable(.bool(false))
            ])
            var options: DesktopPostProcessing.Options? = .init(mode: .remote)
            let retained = try DesktopPostProcessingConfiguration.importOptions(from: source, into: &options)
            XCTAssertEqual(options?.mode, .disabled)
            XCTAssertEqual(options?.modelIdentifier, identifier)
            XCTAssertEqual(try DesktopPostProcessingConfiguration.exportOptions(options, over: retained), source)
        }
    }

    func testAbsentAndPartialImportsPreserveDisabledStateAndRemotePrompt() throws {
        let original = DesktopPostProcessing.Options(customPrompt: "Keep remote prompt.")
        var options: DesktopPostProcessing.Options? = original
        let empty = try DesktopConfiguration()
        XCTAssertEqual(try DesktopPostProcessingConfiguration.importOptions(from: empty, into: &options), empty)
        XCTAssertEqual(options, original)
        let local = try DesktopConfiguration(values: [model: AnyCodable(.string(rules))])
        _ = try DesktopPostProcessingConfiguration.importOptions(from: local, into: &options)
        XCTAssertEqual(options?.mode, .disabled)
        XCTAssertEqual(options?.customPrompt, original.customPrompt)
        let enable = try DesktopConfiguration(values: [enabled: AnyCodable(.bool(true))])
        _ = try DesktopPostProcessingConfiguration.importOptions(from: enable, into: &options)
        XCTAssertEqual(options?.mode, .local)
        _ = try DesktopPostProcessingConfiguration.importOptions(
            from: DesktopConfiguration(values: [enabled: AnyCodable(.bool(false))]), into: &options
        )
        XCTAssertEqual(options?.mode, .disabled)
    }

    func testCloudImportIsNotCredentialOrUploadPermission() throws {
        let identifier = try XCTUnwrap(DesktopPostProcessing.remoteModels.last?.id)
        let source = try DesktopConfiguration(values: [
            model: AnyCodable(.string(identifier)), enabled: AnyCodable(.bool(true))
        ])
        var options: DesktopPostProcessing.Options?
        let retained = try DesktopPostProcessingConfiguration.importOptions(from: source, into: &options)
        XCTAssertEqual(options?.mode, .disabled)
        XCTAssertEqual(retained.values, source.values)
        XCTAssertEqual(try DesktopPostProcessingConfiguration.exportOptions(options, over: retained).values[model],
                       source.values[model])
    }
}
