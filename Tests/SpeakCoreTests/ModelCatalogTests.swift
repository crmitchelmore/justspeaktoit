import XCTest

@testable import SpeakCore

final class ModelCatalogTests: XCTestCase {

    // MARK: - LatencyTier Ordering

    func testLatencyTier_ordering_instantIsFastest() {
        XCTAssertLessThan(LatencyTier.instant, .fast)
        XCTAssertLessThan(LatencyTier.fast, .medium)
        XCTAssertLessThan(LatencyTier.medium, .slow)
    }

    func testLatencyTier_displayName_isHumanReadable() {
        XCTAssertFalse(LatencyTier.instant.displayName.isEmpty)
        XCTAssertFalse(LatencyTier.slow.displayName.isEmpty)
        for tier in LatencyTier.allCases {
            XCTAssertFalse(tier.displayName.isEmpty, "\(tier) should have a display name")
        }
    }

    // MARK: - friendlyName

    func testFriendlyName_knownModel_returnsDisplayName() {
        guard let first = ModelCatalog.allOptions.first else {
            XCTFail("allOptions should not be empty")
            return
        }
        let name = ModelCatalog.friendlyName(for: first.id)
        XCTAssertEqual(name, first.displayName)
    }

    func testFriendlyName_unknownModel_returnsFriendlyFallback() {
        let name = ModelCatalog.friendlyName(for: "some-vendor/cool-model-v2")
        // Should strip vendor prefix and humanise
        XCTAssertFalse(name.contains("/"), "Friendly name should strip vendor prefix")
        XCTAssertFalse(name.isEmpty)
    }

    func testFriendlyName_emptyString_returnsNonEmpty() {
        let name = ModelCatalog.friendlyName(for: "")
        XCTAssertFalse(name.isEmpty, "Should return something even for empty identifier")
    }

    // MARK: - Pricing

    func testPricing_compactDisplay_formatsCorrectly() {
        let pricing = ModelCatalog.Pricing(promptPerMTokens: 0.15, completionPerMTokens: 0.60)
        XCTAssertEqual(pricing.compactDisplay, "$0.15/$0.60")
    }

    // MARK: - Catalog Integrity

    func testAllOptions_containsAllCategories() {
        let allCount = ModelCatalog.allOptions.count
        let sum = ModelCatalog.liveTranscription.count
            + ModelCatalog.batchTranscription.count
            + ModelCatalog.postProcessing.count
        XCTAssertEqual(allCount, sum, "allOptions should be union of all category arrays")
    }

    func testAllOptions_haveUniqueIDsWithinCategories() {
        // IDs may be shared across categories (e.g. same model used for live + batch)
        // but should be unique within each category
        for (name, options) in [
            ("liveTranscription", ModelCatalog.liveTranscription),
            ("batchTranscription", ModelCatalog.batchTranscription),
            ("postProcessing", ModelCatalog.postProcessing),
        ] {
            let ids = options.map(\.id)
            let uniqueIDs = Set(ids)
            XCTAssertEqual(
                ids.count,
                uniqueIDs.count,
                "\(name) should have unique model IDs"
            )
        }
    }

    func testAllOptions_haveNonEmptyDisplayNames() {
        for option in ModelCatalog.allOptions {
            XCTAssertFalse(option.displayName.isEmpty, "\(option.id) should have a display name")
        }
    }

    func testLiveTranscription_allHaveLatencyTiers() {
        for option in ModelCatalog.liveTranscription {
            XCTAssertNotNil(option.latencyTier, "\(option.id) should have a latency tier")
        }
    }
}
