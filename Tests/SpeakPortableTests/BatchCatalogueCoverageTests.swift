import XCTest

@testable import SpeakCore

/// Catches "added to the batch catalogue, forgot the route". The live factory
/// half is Apple-only, so it lives in SpeakCoreTests.
final class BatchCatalogueCoverageTests: XCTestCase {
    func testEveryCataloguedBatchModel_hasARouteOnEveryPlatform() {
        for model in ModelCatalog.batchTranscription {
            for platform in [BatchTranscriptionPlatform.macOS, .iOS] {
                XCTAssertNotNil(BatchTranscriptionRouting.route(for: model.id, platform: platform), model.id)
            }
        }
    }
}
