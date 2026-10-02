import Foundation
import XCTest
@testable import SpeakCore

/// The shared local catalogues replace macOS-owned lists. Entries, pins,
/// order and presentation metadata must stay exactly as they were.
final class LocalModelCatalogPinTests: XCTestCase {
    func testStreamingCatalogueMatchesThePreviousMacOSListFieldForField() throws {
        let previous = try JSONDecoder().decode(
            [LocalStreamingModelSource].self,
            from: Data(LocalModelPersistenceFixtures.recommendedStreamingSources.utf8)
        )

        XCTAssertEqual(previous.count, 7)
        XCTAssertEqual(ModelCatalog.localStreamingSources, previous)
    }

    func testPostProcessingCatalogueMatchesThePreviousMacOSListFieldForField() throws {
        let previous = try JSONDecoder().decode(
            [LocalPostProcessingModel].self,
            from: Data(LocalModelPersistenceFixtures.recommendedPostProcessingModels.utf8)
        )

        XCTAssertEqual(previous.count, 3)
        XCTAssertEqual(ModelCatalog.localPostProcessing, previous)
    }

    func testPostProcessingOptionsKeepTheirPresentationMetadata() {
        for model in ModelCatalog.localPostProcessing {
            let option = model.option
            XCTAssertEqual(option.id, model.id)
            XCTAssertEqual(option.displayName, model.displayName)
            XCTAssertEqual(option.description, model.description)
            XCTAssertEqual(option.estimatedLatencyMs, 2_500)
            XCTAssertEqual(option.latencyTier, .medium)
            XCTAssertEqual(option.tags, [.privacy])
            XCTAssertNil(option.pricing)
            XCTAssertEqual(option.contextLength, 4_096)
        }
    }

    func testRecommendedSourcesLoadWithoutRewritesAndAgreeWithSizeBackfill() {
        for source in ModelCatalog.localStreamingSources {
            XCTAssertEqual(
                LocalStreamingModelSource.knownApproximateSizeMB(repoID: source.repoID, modelName: source.modelName),
                source.approximateSizeMB,
                source.id
            )
            XCTAssertTrue(LocalStreamingModelSource.isRunnableSherpaOnnxSource(source), source.id)
            XCTAssertEqual(LocalStreamingModelSource.normalized(source), source, source.id)
            if let archiveURL = source.archiveURL {
                XCTAssertEqual(archiveURL.scheme, "https", source.id)
            }
        }
        for model in ModelCatalog.localPostProcessing {
            XCTAssertTrue(LocalPostProcessingModel.isGGUFFilename(model.filename), model.id)
        }
    }

    func testLocalCataloguesKeepDownloadedNamespacesFriendlyNamesAndNoLiveRoutes() {
        let transcription = ModelCatalog.localTranscription.map(\.id)
        let streaming = ModelCatalog.localStreamingSources.map(\.id)
        let postProcessing = ModelCatalog.localPostProcessing.map(\.id)
        let all = transcription + streaming + postProcessing

        XCTAssertEqual(Set(all).count, all.count, "Local identifiers must be unique across catalogues")
        for id in all {
            XCTAssertTrue(id.hasPrefix("local/"), id)
            XCTAssertNotEqual(ModelCatalog.friendlyName(for: id), "Downloaded Local Model", id)
            XCTAssertNil(LiveTranscriptionRouting.route(for: id), "\(id) must never become a network live route")
        }
        for id in transcription + streaming {
            XCTAssertTrue(ModelRouting.family(for: id).isDownloadedLocal, id)
        }
        for id in postProcessing {
            XCTAssertTrue(LocalPostProcessingModel.isDownloadedModelID(id), id)
            XCTAssertEqual(ModelRouting.family(for: id), .postProcessing(provider: "local"), id)
        }
    }
}
