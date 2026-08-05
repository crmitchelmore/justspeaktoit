import XCTest
@testable import SpeakCore

final class TranscriptionLanguageTests: XCTestCase {
    func testCatalogue_hasOneAutomaticOptionAndUniqueIdentifiers() {
        let identifiers = TranscriptionLanguageCatalog.options.map(\.id)

        XCTAssertEqual(identifiers.first, TranscriptionLanguageCatalog.automaticIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testProviderLanguage_automaticAllowsProviderDetection() {
        XCTAssertNil(
            TranscriptionLanguageCatalog.providerLanguage(
                for: TranscriptionLanguageCatalog.automaticIdentifier
            )
        )
    }

    func testProviderLanguage_explicitLocaleIsPreserved() {
        XCTAssertEqual(
            TranscriptionLanguageCatalog.providerLanguage(for: "en_GB"),
            "en_GB"
        )
    }

    func testLocaleIdentifier_automaticFallsBackToSystemLocale() {
        XCTAssertEqual(
            TranscriptionLanguageCatalog.localeIdentifier(
                for: TranscriptionLanguageCatalog.automaticIdentifier,
                systemLocaleIdentifier: "cy_GB"
            ),
            "cy_GB"
        )
    }
}
