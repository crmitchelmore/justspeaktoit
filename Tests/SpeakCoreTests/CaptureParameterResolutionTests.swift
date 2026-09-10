import XCTest
@testable import SpeakCore

/// The rule these tests exist to hold: a parameter that is not supplied
/// changes nothing, and a parameter that is wrong stops the recording rather
/// than quietly becoming a different one.
final class CaptureParameterResolutionTests: XCTestCase {
    // MARK: - Nothing supplied behaves exactly as before

    func testResolvingNothingProducesNoOverrides() throws {
        let parameters = try CaptureParameterResolution.resolve()
        XCTAssertEqual(parameters, .none)
        XCTAssertTrue(parameters.isEmpty)
        XCTAssertNil(parameters.destinationID)
        XCTAssertNil(parameters.languageIdentifier)
        XCTAssertNil(parameters.modelID)
        XCTAssertNil(parameters.sourceTag)
        XCTAssertFalse(parameters.requiresBatchMode)
        XCTAssertEqual(parameters.logDescription, "")
    }

    func testEmptyParametersDoNotForceBatchMode() {
        XCTAssertFalse(CaptureRunParameters.none.requiresBatchMode)
    }

    // MARK: - Language

    func testLanguageAcceptsCatalogueIdentifiers() {
        XCTAssertEqual(CaptureParameterResolution.language(from: "en_GB"), "en_GB")
        XCTAssertEqual(CaptureParameterResolution.language(from: "en-GB"), "en_GB")
        XCTAssertEqual(CaptureParameterResolution.language(from: " EN_gb "), "en_GB")
        XCTAssertEqual(CaptureParameterResolution.language(from: "pt_BR"), "pt_BR")
    }

    func testLanguageAcceptsAutomatic() {
        XCTAssertEqual(
            CaptureParameterResolution.language(from: "auto"),
            TranscriptionLanguageCatalog.automaticIdentifier
        )
        XCTAssertEqual(
            CaptureParameterResolution.language(from: "automatic"),
            TranscriptionLanguageCatalog.automaticIdentifier
        )
    }

    /// A bare "en" matches four catalogue locales. Choosing one would be the
    /// silent substitution the parameter exists to prevent.
    func testBareLanguageCodeIsRefused() {
        XCTAssertNil(CaptureParameterResolution.language(from: "en"))
        XCTAssertNil(CaptureParameterResolution.language(from: "klingon"))
        XCTAssertNil(CaptureParameterResolution.language(from: "   "))
    }

    func testUnknownLanguageThrowsRatherThanFallingBack() {
        XCTAssertThrowsError(try CaptureParameterResolution.resolve(language: "en")) { error in
            XCTAssertEqual(error as? CaptureParameterFailure, .unknownLanguage)
        }
    }

    // MARK: - Model

    func testModelAcceptsCatalogueIdentifiersCaseInsensitively() throws {
        let known = try XCTUnwrap(ModelCatalog.liveTranscription.first?.id)
        XCTAssertEqual(CaptureParameterResolution.model(from: known), known)
        XCTAssertEqual(CaptureParameterResolution.model(from: known.uppercased()), known)
        XCTAssertEqual(CaptureParameterResolution.model(from: " \(known) "), known)
    }

    func testModelRefusesTheCustomPlaceholderAndUnknownNames() {
        XCTAssertNil(CaptureParameterResolution.model(from: ModelCatalog.customOptionID))
        XCTAssertNil(CaptureParameterResolution.model(from: "gpt-nonexistent"))
        XCTAssertNil(CaptureParameterResolution.model(from: ""))
    }

    func testUnknownModelThrowsRatherThanFallingBack() {
        XCTAssertThrowsError(try CaptureParameterResolution.resolve(model: "gpt-nonexistent")) { error in
            XCTAssertEqual(error as? CaptureParameterFailure, .unknownModel)
        }
    }

    func testLiveModelDoesNotForceBatchModeButBatchOnlyModelDoes() throws {
        let live = try XCTUnwrap(ModelCatalog.liveTranscription.first?.id)
        XCTAssertFalse(CaptureParameterResolution.requiresBatchMode(live))
        let liveIDs = Set(
            (ModelCatalog.liveTranscription + ModelCatalog.localTranscriptionOptions).map(\.id)
        )
        let batchOnly = try XCTUnwrap(
            ModelCatalog.batchTranscription.first { !liveIDs.contains($0.id) }?.id
        )
        XCTAssertTrue(CaptureParameterResolution.requiresBatchMode(batchOnly))
        let parameters = try CaptureParameterResolution.resolve(model: batchOnly)
        XCTAssertTrue(parameters.requiresBatchMode)
    }

    // MARK: - Source tag

    func testSourceTagIsTrimmedCollapsedAndCapped() {
        XCTAssertEqual(CaptureParameterResolution.sourceTag(from: "  car   NFC \n"), "car NFC")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(
            CaptureParameterResolution.sourceTag(from: long)?.count,
            CaptureParameterResolution.maxSourceTagLength
        )
    }

    func testBlankOrControlCharacterSourceTagIsRefused() {
        XCTAssertNil(CaptureParameterResolution.sourceTag(from: "   "))
        XCTAssertNil(CaptureParameterResolution.sourceTag(from: "desk\u{0007}tag"))
        XCTAssertThrowsError(try CaptureParameterResolution.resolve(source: "  ")) { error in
            XCTAssertEqual(error as? CaptureParameterFailure, .invalidSource)
        }
    }

    // MARK: - Destination precedence

    func testStopDestinationPrefersExplicitThenRunOverrideThenGlobal() {
        XCTAssertEqual(
            CaptureParameterResolution.stopDestinationID(
                explicit: "historyOnly",
                runOverride: "clipboard",
                global: "clipboardAndPostProcess"
            ),
            "historyOnly"
        )
        XCTAssertEqual(
            CaptureParameterResolution.stopDestinationID(
                explicit: nil,
                runOverride: "clipboard",
                global: "clipboardAndPostProcess"
            ),
            "clipboard"
        )
        XCTAssertEqual(
            CaptureParameterResolution.stopDestinationID(
                explicit: nil,
                runOverride: nil,
                global: "clipboardAndPostProcess"
            ),
            "clipboardAndPostProcess"
        )
    }

    // MARK: - Combined

    func testResolvingEveryParameterKeepsAllFour() throws {
        let model = try XCTUnwrap(ModelCatalog.liveTranscription.first?.id)
        let parameters = try CaptureParameterResolution.resolve(
            destinationID: "historyOnly",
            language: "fr-FR",
            model: model,
            source: " car  tag "
        )
        XCTAssertEqual(parameters.destinationID, "historyOnly")
        XCTAssertEqual(parameters.languageIdentifier, "fr_FR")
        XCTAssertEqual(parameters.modelID, model)
        XCTAssertEqual(parameters.sourceTag, "car tag")
        XCTAssertFalse(parameters.isEmpty)
        XCTAssertTrue(parameters.logDescription.contains("destination=historyOnly"))
        XCTAssertTrue(parameters.logDescription.contains("language=fr_FR"))
        XCTAssertTrue(parameters.logDescription.contains("source=car tag"))
    }

    /// One bad value refuses the whole run: no partial application, so a
    /// caller never gets "your destination worked, your model silently did
    /// not".
    func testAnInvalidValueRefusesTheWholeSet() {
        XCTAssertThrowsError(
            try CaptureParameterResolution.resolve(destinationID: "historyOnly", model: "nope")
        ) { error in
            XCTAssertEqual(error as? CaptureParameterFailure, .unknownModel)
        }
    }

    func testEveryFailureHasAUserFacingMessage() {
        for failure in CaptureParameterFailure.allCases {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure) has no message")
        }
    }
}
