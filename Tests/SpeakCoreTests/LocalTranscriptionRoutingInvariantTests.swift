import XCTest
@testable import SpeakCore

final class LocalTranscriptionRoutingInvariantTests: XCTestCase {
    func testCatalogEnginesMatchRouting() {
        for model in ModelCatalog.localTranscription {
            XCTAssertEqual(
                ModelRouting.family(for: model.id),
                .downloadedLocal(engine: model.engine),
                "\(model.id) must route through its declared engine"
            )
        }
    }
}
