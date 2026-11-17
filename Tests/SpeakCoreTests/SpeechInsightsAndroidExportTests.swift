import Foundation
import XCTest

@testable import SpeakCore

/// Android's usage-insights dashboard reads the speech-insights definitions from a committed JSON
/// asset; this keeps it identical to SpeakCore.
final class SpeechInsightsAndroidExportTests: XCTestCase {
    private var assetURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets/speech_insights.json")
    }

    func testAndroidAssetMatchesDefinitions() throws {
        let expected = try SpeechInsightsAndroidExport.json()
        if ProcessInfo.processInfo.environment["UPDATE_SPEECH_INSIGHTS_ANDROID"] == "1" {
            try expected.write(to: assetURL)
        }
        XCTAssertEqual(
            try Data(contentsOf: assetURL), expected,
            "android/app/src/main/assets/speech_insights.json is stale. Regenerate with scripts/update-android-assets"
        )
    }

    func testDocumentCarriesTheDefaultDefinitions() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: SpeechInsightsAndroidExport.json()) as? [String: Any]
        )
        let configuration = SpeechInsightsConfiguration.default
        XCTAssertEqual(object["fillerPhrases"] as? [String], configuration.fillerPhrases)
        XCTAssertEqual((object["stopwords"] as? [String]).map(Set.init), configuration.stopwords)
        XCTAssertEqual(
            object["minimumSessionDurationForWPM"] as? Double, configuration.minimumSessionDurationForWPM
        )
        XCTAssertEqual(object["topPhraseLimit"] as? Int, configuration.topPhraseLimit)
        XCTAssertEqual(object["topFillerLimit"] as? Int, configuration.topFillerLimit)
        XCTAssertEqual(object["fillerTrendWeekLimit"] as? Int, configuration.fillerTrendWeekLimit)

        let buckets = try XCTUnwrap(object["wpmBuckets"] as? [[String: Any]])
        XCTAssertEqual(
            buckets.compactMap { $0["label"] as? String }, SpeechInsightsEngine.wpmBucketBounds.map(\.label)
        )
        XCTAssertNotNil(buckets.last)
        XCTAssertNil(buckets.last?["upperBound"] as? Double, "The top range is open-ended")
        for (bucket, next) in zip(buckets, buckets.dropFirst()) {
            XCTAssertEqual(bucket["upperBound"] as? Double, next["lowerBound"] as? Double)
        }
    }
}
