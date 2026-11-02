import XCTest

@testable import SpeakCore

final class NemotronLocalModelsTests: XCTestCase {
    func testLanguageHint_prefersExactSupportedLocale() {
        XCTAssertEqual(NemotronLocalModels.languageHint(forLocaleIdentifier: "pt_PT"), "pt-PT")
        XCTAssertEqual(NemotronLocalModels.languageHint(forLocaleIdentifier: "en-gb"), "en-GB")
    }

    func testLanguageHint_fallsBackToSupportedLanguageCode() {
        XCTAssertEqual(NemotronLocalModels.languageHint(forLocaleIdentifier: "ja"), "ja")
        XCTAssertEqual(NemotronLocalModels.languageHint(forLocaleIdentifier: "de-AT"), "de")
        XCTAssertEqual(NemotronLocalModels.languageHint(forLocaleIdentifier: "no"), "nb")
    }

    func testLanguageHint_autoDetectsForAutomaticAndUnsupportedLanguages() {
        XCTAssertNil(NemotronLocalModels.languageHint(forLocaleIdentifier: nil))
        XCTAssertNil(NemotronLocalModels.languageHint(forLocaleIdentifier: "auto"))
        // Adaptation-ready locales need fine-tuning, so they are never forced.
        XCTAssertNil(NemotronLocalModels.languageHint(forLocaleIdentifier: "el-GR"))
        XCTAssertNil(NemotronLocalModels.languageHint(forLocaleIdentifier: "cy"))
    }

    func testCatalogue_listsEveryVariantWithPinnedArchive() {
        for variant in NemotronLocalModels.multilingualVariants {
            let source = ModelCatalog.localStreamingSources.first { $0.modelName == variant.modelName }
            XCTAssertEqual(source?.archiveURL, variant.archiveURL)
            XCTAssertEqual(source?.approximateSizeMB, NemotronLocalModels.multilingualDownloadSizeMB)
            XCTAssertEqual(variant.archiveSHA256.count, 64)
        }
    }
}
