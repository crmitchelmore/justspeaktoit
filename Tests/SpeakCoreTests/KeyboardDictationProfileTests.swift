import XCTest

@testable import SpeakCore

final class KeyboardDictationProfileTests: XCTestCase {
    func testCatalogueOffersLocalAndExactAppModeWithinTwoTaps() {
        let selection = makeSelection()

        XCTAssertEqual(
            selection.availableProfiles.map(\.id),
            [KeyboardDictationProfileCatalog.directIdentifier, KeyboardDictationProfileCatalog.appIdentifier]
        )
        XCTAssertLessThanOrEqual(
            selection.availableProfiles.count - 1,
            KeyboardDictationProfileCatalog.maxCycleTaps
        )
        XCTAssertEqual(selection.selectedIdentifier, KeyboardDictationProfileCatalog.appIdentifier)
        XCTAssertEqual(selection.nextQuickIdentifier, KeyboardDictationProfileCatalog.directIdentifier)
    }

    func testAppProjectionPreservesExecutionConfigurationWithoutCredentials() throws {
        let selection = makeSelection()
        let profile = selection.selectedProfile

        XCTAssertEqual(profile.route, .appHandoff)
        XCTAssertEqual(profile.transcriptionMode, .batch)
        XCTAssertEqual(profile.transcriptionModelIdentifier, "openai/gpt-transcribe")
        XCTAssertEqual(profile.languageIdentifier, "en_GB")
        XCTAssertTrue(profile.postProcessingEnabled)
        XCTAssertEqual(profile.postProcessingModelIdentifier, "openai/gpt-5-mini")

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(selection), encoding: .utf8))
        let lowercased = encoded.lowercased()
        XCTAssertFalse(lowercased.contains("apikey"))
        XCTAssertFalse(lowercased.contains("secret"))
        XCTAssertFalse(lowercased.contains("token"))
        XCTAssertFalse(lowercased.contains("prompt"))
    }

    func testLocalModeStaysAvailableWithoutFoundationModels() {
        let selection = makeSelection(postProcessingModel: AppleLocalModels.foundationModelID)
        let local = selection.availableProfiles[0]

        XCTAssertEqual(local.route, .directAppleSpeech)
        XCTAssertFalse(local.polishes)
        XCTAssertEqual(local.transcriptionModelIdentifier, AppleLocalModels.legacySpeechModelID)
        XCTAssertEqual(selection.availableProfiles[1].route, .appHandoff)
    }

    func testRetiredSelectionFallsBackToAppDefault() {
        let selection = KeyboardDictationProfileCatalog.selection(
            for: configuration,
            selectedIdentifier: "retired-profile"
        )

        XCTAssertEqual(selection.selectedIdentifier, KeyboardDictationProfileCatalog.appIdentifier)
        XCTAssertEqual(selection.selectedProfile.route, .appHandoff)
    }

    func testSelectionRoundTripsWithCatalogueRevision() throws {
        let selection = makeSelection().selecting(KeyboardDictationProfileCatalog.directIdentifier)
        let decoded = try JSONDecoder().decode(
            KeyboardProfileSelection.self,
            from: JSONEncoder().encode(selection)
        )

        XCTAssertEqual(decoded, selection)
        XCTAssertEqual(decoded.selectedProfile.route, .directAppleSpeech)
    }

    func testRewriteRequiresTheEntireObservedDocumentContextToStayUnchanged() {
        let dictated = "A long dictated sentence with an unchanged final twenty-four chars."
        let original = "Host prefix. \(dictated)"

        XCTAssertTrue(
            KeyboardDocumentRewriteGuard.canReplace(
                dictatedText: dictated,
                contextAtPolishStart: original,
                currentContext: original
            )
        )
        XCTAssertFalse(
            KeyboardDocumentRewriteGuard.canReplace(
                dictatedText: dictated,
                contextAtPolishStart: original,
                currentContext: "Changed host prefix. \(dictated)"
            ),
            "An earlier edit with the same trailing anchor must never authorise full replacement"
        )
        XCTAssertFalse(
            KeyboardDocumentRewriteGuard.canReplace(
                dictatedText: dictated,
                contextAtPolishStart: String(dictated.suffix(24)),
                currentContext: String(dictated.suffix(24))
            ),
            "A truncated proxy context cannot prove ownership of the whole deletion"
        )
    }

    private var configuration: KeyboardAppProfileConfiguration {
        KeyboardAppProfileConfiguration(
            transcriptionMode: .batch,
            transcriptionModelIdentifier: "openai/gpt-transcribe",
            languageIdentifier: "en_GB",
            postProcessingEnabled: true,
            postProcessingModelIdentifier: "openai/gpt-5-mini"
        )
    }

    private func makeSelection(postProcessingModel: String = "openai/gpt-5-mini") -> KeyboardProfileSelection {
        KeyboardDictationProfileCatalog.selection(
            for: KeyboardAppProfileConfiguration(
                transcriptionMode: .batch,
                transcriptionModelIdentifier: "openai/gpt-transcribe",
                languageIdentifier: "en_GB",
                postProcessingEnabled: true,
                postProcessingModelIdentifier: postProcessingModel
            ),
            revision: 7,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
