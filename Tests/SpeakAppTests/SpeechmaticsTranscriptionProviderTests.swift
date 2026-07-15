import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

final class SpeechmaticsTranscriptionProviderTests: XCTestCase {
  func testModelCatalogLiveTranscription_includesSpeechmaticsEnhanced() {
    let ids = ModelCatalog.liveTranscription.map(\.id)

    XCTAssertTrue(ids.contains("speechmatics/enhanced-streaming"))
  }

  func testProviderRegistry_routesSpeechmaticsLiveToSpeechmaticsProvider() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "speechmatics/enhanced-streaming")

    XCTAssertEqual(provider?.metadata.id, "speechmatics")
  }

  func testLiveCapabilities_enableLivePolishAndPostStopBudget() {
    let capabilities = ModelCatalog.liveCapabilities(for: "speechmatics/enhanced-streaming")

    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.instant))
    XCTAssertTrue(capabilities.supportedSpeedModes.contains(.livePolish))
    XCTAssertEqual(capabilities.postStopFinalizeBudget, 2.0)
  }

  func testStartRecognitionPayload_usesRawPCM16kPartialsAndLanguage() throws {
    let payload = try SpeechmaticsLiveTranscriber.startRecognitionPayload(
      language: "en_GB",
      model: "enhanced",
      sampleRate: 16000
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )

    XCTAssertEqual(object["message"] as? String, "StartRecognition")
    let audioFormat = try XCTUnwrap(object["audio_format"] as? [String: Any])
    XCTAssertEqual(audioFormat["type"] as? String, "raw")
    XCTAssertEqual(audioFormat["encoding"] as? String, "pcm_s16le")
    XCTAssertEqual(audioFormat["sample_rate"] as? Int, 16000)

    let config = try XCTUnwrap(object["transcription_config"] as? [String: Any])
    XCTAssertEqual(config["language"] as? String, "en")
    XCTAssertEqual(config["model"] as? String, "enhanced")
    XCTAssertEqual(config["enable_partials"] as? Bool, true)
    XCTAssertEqual(config["max_delay"] as? Double, 0.7)
  }

  func testTranscriptEvent_parsesPartialMetadataTranscript() throws {
    let json = #"""
    {
      "message": "AddPartialTranscript",
      "format": "2.1",
      "metadata": {
        "start_time": 0.0,
        "end_time": 0.5,
        "transcript": "hello wor"
      },
      "results": []
    }
    """#

    let event = try XCTUnwrap(SpeechmaticsLiveTranscriber.transcriptEvent(from: json))

    XCTAssertEqual(event.text, "hello wor")
    XCTAssertFalse(event.isFinal)
    XCTAssertTrue(event.segments.isEmpty)
    XCTAssertNil(event.confidence)
  }

  func testEndOfStreamSequence_usesSentFrameCountWhenAcknowledgementsLag() {
    XCTAssertEqual(
      SpeechmaticsLiveTranscriber.endOfStreamLastSequenceNumber(lastAcknowledged: 2, sentFrameCount: 3),
      3
    )
  }

  func testEndOfStreamSequence_usesHighestAcknowledgement() {
    XCTAssertEqual(
      SpeechmaticsLiveTranscriber.endOfStreamLastSequenceNumber(lastAcknowledged: 4, sentFrameCount: 3),
      4
    )
  }

  func testTranscriptEvent_parsesFinalMetadataAndSegments() throws {
    let json = #"""
    {
      "message": "AddTranscript",
      "format": "2.1",
      "metadata": {
        "start_time": 0.0,
        "end_time": 1.1,
        "transcript": "Hello, world."
      },
      "results": [
        {
          "type": "word",
          "start_time": 0.0,
          "end_time": 0.4,
          "alternatives": [{"content": "Hello", "confidence": 0.9, "speaker": "S1"}]
        },
        {
          "type": "punctuation",
          "start_time": 0.4,
          "end_time": 0.4,
          "alternatives": [{"content": ",", "confidence": 1.0}]
        },
        {
          "type": "word",
          "start_time": 0.6,
          "end_time": 1.1,
          "alternatives": [{"content": "world", "confidence": 0.8}]
        }
      ]
    }
    """#

    let event = try XCTUnwrap(SpeechmaticsLiveTranscriber.transcriptEvent(from: json))

    XCTAssertEqual(event.text, "Hello, world.")
    XCTAssertTrue(event.isFinal)
    XCTAssertEqual(event.startTime, 0.0)
    XCTAssertEqual(event.endTime, 1.1)
    XCTAssertEqual(event.segments.map(\.text), ["Hello", ",", "world"])
    XCTAssertEqual(event.confidence ?? 0, 0.9, accuracy: 0.0001)
  }

  func testValidateAPIKey_sendsAuthorizationHeaderToSpeechmaticsJobsEndpoint() async throws {
    let requestObserver = SpeechmaticsRequestObserver()
    SpeechmaticsMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"jobs":[]} "#.utf8))
    }
    defer { SpeechmaticsMockURLProtocol.requestHandler = nil }

    let provider = SpeechmaticsTranscriptionProvider(session: makeMockSession())
    let result = await provider.validateAPIKey("test-speechmatics-key")

    if case .success = result.outcome {
      // Expected.
    } else {
      XCTFail("Expected validation success")
    }
    let capturedRequest = await requestObserver.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.host, "eu1.asr.api.speechmatics.com")
    XCTAssertEqual(request.url?.path, "/v2/jobs")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-speechmatics-key")
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpeechmaticsMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private actor SpeechmaticsRequestObserver {
  private var request: URLRequest?

  func store(request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }
}

private final class SpeechmaticsMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("SpeechmaticsMockURLProtocol.requestHandler was not set")
      return
    }

    Task {
      do {
        let (response, data) = try await handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {}
}
