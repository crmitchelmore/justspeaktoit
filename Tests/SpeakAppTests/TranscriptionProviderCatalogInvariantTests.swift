import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Guards the single-source invariant between ModelCatalog and the providers:
/// the pickers read the catalogue while routing reads each provider's
/// `supportedModels()`, so a model declared by a provider but missing from the
/// catalogue (or vice versa) silently breaks one of the two.
final class TranscriptionProviderCatalogInvariantTests: XCTestCase {
  func testAllProviderSupportedModels_areSubsetOfModelCatalog() async {
    let registry = TranscriptionProviderRegistry.shared
    let catalogIDs = Set(
      (ModelCatalog.batchTranscription + ModelCatalog.liveTranscription).map(\.id)
    )

    for metadata in await registry.allProviders() {
      guard let provider = await registry.provider(withID: metadata.id) else {
        XCTFail("Registry lists \(metadata.id) but returns no provider for it")
        continue
      }
      for model in provider.supportedModels() {
        XCTAssertTrue(
          catalogIDs.contains(model.id),
          "\(metadata.id) supports \(model.id), which is missing from ModelCatalog"
        )
      }
    }
  }

  func testAllProviderSupportedModels_routeBackToTheirProvider() async {
    let registry = TranscriptionProviderRegistry.shared

    for metadata in await registry.allProviders() {
      guard let provider = await registry.provider(withID: metadata.id) else { continue }
      for model in provider.supportedModels() {
        let routed = await registry.provider(forModel: model.id)
        XCTAssertEqual(
          routed?.metadata.id,
          metadata.id,
          "\(model.id) should route to the \(metadata.id) provider"
        )
      }
    }
  }
}
