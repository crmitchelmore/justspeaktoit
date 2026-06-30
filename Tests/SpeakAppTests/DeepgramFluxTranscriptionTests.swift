import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class DeepgramFluxTranscriptionTests: XCTestCase {
  func testModelCatalogLiveTranscription_includesFluxModels() {
    let ids = ModelCatalog.liveTranscription.map(\.id)

    XCTAssertTrue(ids.contains("deepgram/flux-general-en-streaming"))
    XCTAssertTrue(ids.contains("deepgram/flux-general-multi-streaming"))
  }

  func testFluxModelsSupportLivePolish() {
    let english = ModelCatalog.liveCapabilities(for: "deepgram/flux-general-en-streaming")
    let multilingual = ModelCatalog.liveCapabilities(for: "deepgram/flux-general-multi-streaming")

    XCTAssertTrue(english.supportedSpeedModes.contains(.livePolish))
    XCTAssertTrue(multilingual.supportedSpeedModes.contains(.livePolish))
  }

  func testWebSocketURL_fluxUsesV2EndpointAndFluxParameters() throws {
    let url = try XCTUnwrap(
      DeepgramLiveTranscriber.webSocketURL(
        model: "flux-general-en",
        language: "en_GB",
        sampleRate: 16_000
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })

    XCTAssertEqual(components.scheme, "wss")
    XCTAssertEqual(components.host, "api.deepgram.com")
    XCTAssertEqual(components.path, "/v2/listen")
    XCTAssertEqual(query["model"], "flux-general-en")
    XCTAssertEqual(query["encoding"], "linear16")
    XCTAssertEqual(query["sample_rate"], "16000")
    XCTAssertNil(query["language"])
    XCTAssertNil(query["language_hint"])
  }

  func testWebSocketURL_fluxMultilingualUsesLanguageHint() throws {
    let url = try XCTUnwrap(
      DeepgramLiveTranscriber.webSocketURL(
        model: "flux-general-multi",
        language: "es_ES",
        sampleRate: 16_000
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })

    XCTAssertEqual(components.path, "/v2/listen")
    XCTAssertEqual(query["model"], "flux-general-multi")
    XCTAssertEqual(query["language_hint"], "es")
  }

  func testWebSocketURL_novaKeepsV1EndpointAndLanguageParameter() throws {
    let url = try XCTUnwrap(
      DeepgramLiveTranscriber.webSocketURL(model: "nova-3", language: "en_GB", sampleRate: 16_000)
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })

    XCTAssertEqual(components.path, "/v1/listen")
    XCTAssertEqual(query["model"], "nova-3")
    XCTAssertEqual(query["interim_results"], "true")
    XCTAssertEqual(query["language"], "en")
  }

  func testTranscriptEvent_fluxUpdateProducesPartial() {
    let json = #"{"event":"Update","transcript":"Hello there"}"#
    let event = DeepgramLiveTranscriber.transcriptEvent(from: json, model: "flux-general-en")

    XCTAssertEqual(event?.text, "Hello there")
    XCTAssertEqual(event?.isFinal, false)
  }

  func testTranscriptEvent_fluxEndOfTurnProducesFinal() {
    let json = #"{"event":"EndOfTurn","transcript":"Hello there."}"#
    let event = DeepgramLiveTranscriber.transcriptEvent(from: json, model: "flux-general-en")

    XCTAssertEqual(event?.text, "Hello there.")
    XCTAssertEqual(event?.isFinal, true)
  }

  func testTranscriptEvent_fluxEmptyTranscriptIsIgnored() {
    let json = #"{"event":"Update","transcript":""}"#
    let event = DeepgramLiveTranscriber.transcriptEvent(from: json, model: "flux-general-en")

    XCTAssertNil(event)
  }

  func testTranscriptEvent_novaResponseStillParses() {
    let json = """
    {
      "channel": {
        "alternatives": [
          {"transcript": "Nova transcript", "confidence": 0.9}
        ]
      },
      "is_final": true
    }
    """

    let event = DeepgramLiveTranscriber.transcriptEvent(from: json, model: "nova-3")

    XCTAssertEqual(event?.text, "Nova transcript")
    XCTAssertEqual(event?.isFinal, true)
  }
}
