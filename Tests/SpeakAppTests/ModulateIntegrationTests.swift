import Foundation
import XCTest

@testable import SpeakApp

final class ModulateIntegrationTests: XCTestCase {
  @MainActor
  func testHasSelectedModulateModelChecksProviderPrefixOnly() {
    let suiteName = "ModulateIntegrationTests-AppSettings-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated defaults suite")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let settings = AppSettings(defaults: defaults)
    settings.liveTranscriptionModel = "openrouter/modulate-helper"
    settings.batchTranscriptionModel = "openai/whisper-1"
    XCTAssertFalse(settings.hasSelectedModulateModel)

    settings.batchTranscriptionModel = "modulate/velma-2-stt-batch"
    XCTAssertTrue(settings.hasSelectedModulateModel)
  }

  func testFeatureConfigurationBuildsExpectedQueryItems() {
    let configuration = ModulateFeatureConfiguration(
      speakerDiarization: true,
      emotionSignal: true,
      accentSignal: false,
      piiPhiTagging: true
    )

    let query: [String: String] = Dictionary(
      uniqueKeysWithValues: configuration.queryItems.compactMap { item in
        guard let value = item.value else { return nil }
        return (item.name, value)
      }
    )

    XCTAssertEqual(query["speaker_diarization"], "true")
    XCTAssertEqual(query["emotion_signal"], "true")
    XCTAssertEqual(query["accent_signal"], "false")
    XCTAssertEqual(query["pii_phi_tagging"], "true")
  }

  func testFeatureConfigurationReadsPersistedDefaults() {
    let suiteName = "ModulateIntegrationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated defaults suite")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(false, forKey: AppSettings.DefaultsKey.modulateSpeakerDiarization.rawValue)
    defaults.set(true, forKey: AppSettings.DefaultsKey.modulateEmotionSignal.rawValue)
    defaults.set(true, forKey: AppSettings.DefaultsKey.modulateAccentSignal.rawValue)
    defaults.set(false, forKey: AppSettings.DefaultsKey.modulatePIIPhiTagging.rawValue)

    let configuration = ModulateFeatureConfiguration(defaults: defaults)

    XCTAssertFalse(configuration.speakerDiarization)
    XCTAssertTrue(configuration.emotionSignal)
    XCTAssertTrue(configuration.accentSignal)
    XCTAssertFalse(configuration.piiPhiTagging)
  }

  func testFormattedTranscriptAddsSpeakerLabelsWhenMultipleSpeakersPresent() {
    let configuration = ModulateFeatureConfiguration(
      speakerDiarization: true,
      emotionSignal: false,
      accentSignal: false,
      piiPhiTagging: false
    )
    let utterances = [
      ModulateUtterance(
        utteranceUUID: UUID(),
        text: "Hello there",
        startMs: 0,
        durationMs: 800,
        speaker: 1,
        language: "en",
        emotion: nil,
        accent: nil
      ),
      ModulateUtterance(
        utteranceUUID: UUID(),
        text: "Hi!",
        startMs: 900,
        durationMs: 500,
        speaker: 2,
        language: "en",
        emotion: nil,
        accent: nil
      )
    ]

    let transcript = configuration.formattedTranscript(from: utterances, fallbackText: "Hello there Hi!")

    XCTAssertEqual(transcript, "Speaker 1: Hello there\nSpeaker 2: Hi!")
  }

  func testSegmentTextOmitsSpeakerLabelWhenOnlyOneSpeakerDetected() {
    let configuration = ModulateFeatureConfiguration(
      speakerDiarization: true,
      emotionSignal: false,
      accentSignal: false,
      piiPhiTagging: false
    )
    let utterances = [
      ModulateUtterance(
        utteranceUUID: UUID(),
        text: "Only me",
        startMs: 0,
        durationMs: 500,
        speaker: 1,
        language: "en",
        emotion: nil,
        accent: nil
      )
    ]

    XCTAssertEqual(configuration.formattedTranscript(from: utterances, fallbackText: "Only me"), "Only me")
    XCTAssertEqual(configuration.segmentText(for: utterances[0], within: utterances), "Only me")
  }

  func testValidationRequestIncludesAudioFileAndValidationResultRedactsHeaders() async throws {
    let requestObserver = RequestObserver()
    MockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 403,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let data = Data(#"{"detail":"invalid_api_key"}"#.utf8)
      return (response, data)
    }
    defer {
      MockURLProtocol.requestHandler = nil
    }

    let session = makeMockSession()
    let provider = ModulateTranscriptionProvider(session: session)

    let result = await provider.validateAPIKey("definitely-invalid-key")
    let capturedRequest = await requestObserver.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(requestBodyData(from: request))

    XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "definitely-invalid-key")
    XCTAssertNotNil(body.range(of: Data("name=\"upload_file\"".utf8)))
    XCTAssertNotNil(body.range(of: Data("filename=\"validation.wav\"".utf8)))
    XCTAssertNotNil(body.range(of: Data("Content-Type: audio/wav".utf8)))

    guard case let .failure(message) = result.outcome else {
      XCTFail("Expected invalid key to fail validation")
      return
    }
    XCTAssertEqual(message, "Invalid API key.")
    XCTAssertNotEqual(result.debug?.requestHeaders["X-API-Key"], "definitely-invalid-key")
    XCTAssertEqual(result.debug?.requestHeaders["X-API-Key"], "def...-key")
  }

  func testTranscriptionProviderRegistryIncludesModulate() async {
    let registry = TranscriptionProviderRegistry.shared

    let provider = await registry.provider(withID: "modulate")

    XCTAssertNotNil(provider)
    XCTAssertEqual(provider?.metadata.apiKeyIdentifier, "modulate.apiKey")
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer {
      stream.close()
    }

    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while stream.hasBytesAvailable {
      let readCount = stream.read(&buffer, maxLength: buffer.count)
      guard readCount >= 0 else { return nil }
      guard readCount > 0 else { break }
      data.append(buffer, count: readCount)
    }

    return data
  }
}

private actor RequestObserver {
  private(set) var request: URLRequest?

  func store(request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }
}

private final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("MockURLProtocol.requestHandler was not set")
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
