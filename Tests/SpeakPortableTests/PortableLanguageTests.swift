import XCTest
@testable import SpeakCore

final class PortableLanguageTests: XCTestCase {
    func testAutomaticAliasesUseOneStoredIdentifierAndNoProviderHint() {
        for value in ["", " ", "automatic", "Automatic", " AUTOMATIC ", "auto", "Auto"] {
            XCTAssertEqual(TranscriptionLanguageCatalog.normalizedIdentifier(value), "automatic")
            XCTAssertNil(TranscriptionLanguageCatalog.providerLanguage(for: value))
        }
    }

    func testExplicitLocalesAndUnknownSelectionsRemainIntact() {
        for value in ["en_GB", "pt-BR", "cy_GB", "future_language"] {
            XCTAssertEqual(TranscriptionLanguageCatalog.providerLanguage(for: " \(value) "), value)
        }
    }
}
