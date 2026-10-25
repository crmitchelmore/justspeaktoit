import XCTest
@testable import SpeakCore

final class FocusCaptureConfigurationTests: XCTestCase {
    private let globals = EffectiveCaptureConfiguration.Globals(
        modelID: "global-model", usesBatch: true, languageIdentifier: "en_US", destinationID: "clipboard"
    )

    func testExplicitFieldsSupersedeInvalidFocusWithoutErasingOtherFields() throws {
        let resolved = try EffectiveCaptureConfiguration.resolve(
            explicit: CaptureRunParameters(destinationID: "clipboard", languageIdentifier: "en_GB"),
            focus: FocusCaptureOverride(destinationID: "deleted", languageIdentifier: "deleted"),
            globals: globals, vocabulary: CaptureParameterVocabulary(destinationIDs: ["clipboard", "historyOnly"])
        )
        XCTAssertEqual(resolved.destinationOrigin, .explicit)
        XCTAssertEqual(resolved.languageIdentifier, "en_GB")
        XCTAssertEqual(resolved.modelID, "global-model")
        XCTAssertEqual(resolved.modelOrigin, .global)
        XCTAssertTrue(resolved.usesBatch)
    }

    func testUnshadowedInvalidFocusIsRefusedInsteadOfGlobalFallback() {
        XCTAssertThrowsError(try EffectiveCaptureConfiguration.resolve(
            explicit: .none, focus: FocusCaptureOverride(modelID: "deleted"),
            globals: globals, vocabulary: .unconstrained
        )) { XCTAssertEqual($0 as? CaptureParameterFailure, .unknownModel) }
    }

    func testFocusDestinationAndLanguageAreFrozenWithOriginsAndSourceUnchanged() throws {
        let resolved = try EffectiveCaptureConfiguration.resolve(
            explicit: CaptureRunParameters(sourceTag: "shortcut"),
            focus: FocusCaptureOverride(destinationID: "historyOnly", languageIdentifier: "en-GB"),
            globals: globals, vocabulary: .unconstrained
        )
        XCTAssertEqual(resolved.destinationID, "historyOnly")
        XCTAssertEqual(resolved.destinationOrigin, .focus)
        XCTAssertEqual(resolved.languageIdentifier, "en_GB")
        XCTAssertEqual(resolved.languageOrigin, .focus)
        XCTAssertEqual(resolved.parameters.sourceTag, "shortcut")
        XCTAssertEqual(resolved.parameters.modelID, nil)
    }

    func testResetRestoresGlobalFieldOriginsWithoutConvertingGlobalsToExplicitModels() throws {
        let resolved = try EffectiveCaptureConfiguration.resolve(
            explicit: .none, focus: .none, globals: globals, vocabulary: .unconstrained
        )
        XCTAssertEqual(resolved.parameters, .none)
        XCTAssertEqual(resolved.destinationID, "clipboard")
        XCTAssertEqual(resolved.destinationOrigin, .global)
        XCTAssertEqual(resolved.modelOrigin, .global)
    }
    func testNamedFocusModelDerivesModeAndRemainsAnExplicitModelRequest() throws {
        let model = try XCTUnwrap(ModelCatalog.batchTranscription.first {
            CaptureParameterResolution.requiresBatchMode($0.id)
        })
        let resolved = try EffectiveCaptureConfiguration.resolve(
            explicit: .none, focus: FocusCaptureOverride(modelID: model.id),
            globals: EffectiveCaptureConfiguration.Globals(
                modelID: "global-live", usesBatch: false, languageIdentifier: "en_US", destinationID: "clipboard"
            ), vocabulary: .unconstrained
        )
        XCTAssertTrue(resolved.usesBatch)
        XCTAssertEqual(resolved.modelOrigin, .focus)
        XCTAssertEqual(resolved.parameters.modelID, model.id)
    }

    func testBlankExplicitFieldsCannotEraseValidFocusChoices() throws {
        let model = try XCTUnwrap(ModelCatalog.liveTranscription.first?.id)
        let focus = FocusCaptureOverride(destinationID: "historyOnly", modelID: model, languageIdentifier: "en_GB")
        let explicit = CaptureRunParameters(destinationID: "  ", languageIdentifier: "", modelID: " \t\n")
        let resolved = try EffectiveCaptureConfiguration.resolve(
            explicit: explicit, focus: focus, globals: globals, vocabulary: .unconstrained
        )
        XCTAssertTrue(focus.affects(explicit))
        XCTAssertEqual(resolved.modelID, model)
        XCTAssertEqual(resolved.languageIdentifier, "en_GB")
        XCTAssertEqual(resolved.destinationID, "historyOnly")
        XCTAssertEqual(resolved.modelOrigin, .focus)
        XCTAssertEqual(resolved.languageOrigin, .focus)
        XCTAssertEqual(resolved.destinationOrigin, .focus)
    }

    func testAllBlankFocusFieldsMeanDefaultResetIncludingDecodedInput() throws {
        XCTAssertEqual(FocusCaptureOverride(destinationID: "", modelID: " ", languageIdentifier: "\t\n"), .none)
        let encoded = Data(#"{"destinationID":" ","modelID":"","languageIdentifier":"   "}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FocusCaptureOverride.self, from: encoded), .none)
    }

}
