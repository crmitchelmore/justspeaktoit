import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class CartesiaTranscriptionProviderTests: XCTestCase {
  func testModelCatalogLiveTranscription_includesInk2() {
    let ids = ModelCatalog.liveTranscription.map(\.id)

    XCTAssertTrue(ids.contains("cartesia/ink-2-streaming"))
  }

  func testInk2SupportsLivePolish() {
    let capabilities = ModelCatalog.liveCapabilities(for: "cartesia/ink-2-streaming")

    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
  }

  func testProviderRegistry_routesCartesiaModelToCartesiaProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "cartesia/ink-2-streaming")

    XCTAssertEqual(provider?.metadata.id, "cartesia")
  }

  func testWebSocketURL_usesTurnsEndpointAndInk2Parameters() throws {
    let url = try XCTUnwrap(CartesiaLiveTranscriber.webSocketURL(model: "ink-2", sampleRate: 16_000))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })

    XCTAssertEqual(components.scheme, "wss")
    XCTAssertEqual(components.host, "api.cartesia.ai")
    XCTAssertEqual(components.path, "/stt/turns/websocket")
    XCTAssertEqual(query["model"], "ink-2")
    XCTAssertEqual(query["encoding"], "pcm_s16le")
    XCTAssertEqual(query["sample_rate"], "16000")
    XCTAssertEqual(query["cartesia_version"], CartesiaLiveTranscriber.apiVersion)
  }

  func testTranscriptEvent_turnUpdateProducesPartial() {
    let json = """
    {"type":"turn.update","results":[{"transcript":"book a table"}]}
    """

    let event = CartesiaLiveTranscriber.transcriptEvent(from: json)

    XCTAssertEqual(event?.text, "book a table")
    XCTAssertEqual(event?.isFinal, false)
  }

  func testTranscriptEvent_turnEndProducesFinal() {
    let json = """
    {"type":"turn.end","results":[{"transcript":"book a table for two"}]}
    """

    let event = CartesiaLiveTranscriber.transcriptEvent(from: json)

    XCTAssertEqual(event?.text, "book a table for two")
    XCTAssertEqual(event?.isFinal, true)
  }

  func testTranscriptEvent_ignoresEmptyTranscript() {
    let json = #"{"type":"turn.update","results":[{"transcript":""}]}"#

    XCTAssertNil(CartesiaLiveTranscriber.transcriptEvent(from: json))
  }
}
