import Foundation
import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Covers what actually travels to Cartesia: endpoint, headers, JSON body, and
/// the two authenticated GET calls behind key validation and voice listing.
final class CartesiaTTSClientTests: XCTestCase {
  func testSynthesizeRequest_usesBytesEndpointAndBothRequiredHeaders() async throws {
    let recorded = try await recordSynthesisRequest()

    XCTAssertEqual(recorded.url?.absoluteString, "https://api.cartesia.ai/tts/bytes")
    XCTAssertEqual(recorded.httpMethod, "POST")
    XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer sk_car_test")
    XCTAssertEqual(recorded.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
    XCTAssertEqual(recorded.value(forHTTPHeaderField: "Content-Type"), "application/json")
  }

  func testSynthesizeRequest_sendsSonic36AndTheSelectedVoiceAndFormat() async throws {
    let body = try await recordSynthesisBody()

    XCTAssertEqual(body["model_id"] as? String, "sonic-3.6")
    XCTAssertEqual(body["transcript"] as? String, "Hello there")

    let voice = try XCTUnwrap(body["voice"] as? [String: Any])
    XCTAssertEqual(voice["mode"] as? String, "id")
    XCTAssertEqual(voice["id"] as? String, CartesiaTTSCatalog.defaultVoice.id)

    let outputFormat = try XCTUnwrap(body["output_format"] as? [String: Any])
    XCTAssertEqual(outputFormat["container"] as? String, "wav")
    XCTAssertEqual(outputFormat["encoding"] as? String, "pcm_s16le")
    XCTAssertEqual(outputFormat["sample_rate"] as? Int, 24_000)
  }

  func testValidateAPIKey_probesTheVoicesEndpointWithBothHeaders() async throws {
    CartesiaTTSMockURLProtocol.requestHandler = { request in
      (Self.response(for: request, statusCode: 200), Data(#"{"data":[],"has_more":false}"#.utf8))
    }
    defer { CartesiaTTSMockURLProtocol.requestHandler = nil }

    let api = CartesiaTTSAPI(session: Self.makeMockSession())
    let result = await api.validateAPIKey("sk_car_test")

    let recorded = try XCTUnwrap(CartesiaTTSMockURLProtocol.lastRequest)
    let components = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(recorded.url), resolvingAgainstBaseURL: false)
    )
    XCTAssertEqual(components.host, "api.cartesia.ai")
    XCTAssertEqual(components.path, "/voices")
    XCTAssertEqual(recorded.httpMethod, "GET")
    XCTAssertEqual(recorded.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
    XCTAssertEqual(result.outcome, .success(message: "Cartesia API key validated"))
    // The snapshot is rendered in the debug UI, so the key must not survive it.
    let authorization = try XCTUnwrap(result.debug?.requestHeaders["Authorization"])
    XCTAssertFalse(authorization.contains("sk_car_test"))
  }

  func testValidateAPIKey_reportsARejectedKey() async {
    CartesiaTTSMockURLProtocol.requestHandler = { request in
      (Self.response(for: request, statusCode: 401), Data(#"{"error":"unauthorized"}"#.utf8))
    }
    defer { CartesiaTTSMockURLProtocol.requestHandler = nil }

    let api = CartesiaTTSAPI(session: Self.makeMockSession())
    let result = await api.validateAPIKey("sk_car_bad")

    XCTAssertEqual(result.outcome, .failure(message: "Cartesia rejected the key (HTTP 401)"))
  }

  func testListVoices_followsPaginationAndKeepsEveryVoice() async throws {
    let pages = [
      #"{"data":[{"id":"a","name":"Ada","language":"en"}],"has_more":true,"next_page":"a"}"#,
      #"{"data":[{"id":"b","name":"Bo","language":"fr"}],"has_more":false}"#
    ]
    let pageIndex = CartesiaTTSPageCounter()
    CartesiaTTSMockURLProtocol.requestHandler = { request in
      let index = pageIndex.next()
      return (Self.response(for: request, statusCode: 200), Data(pages[min(index, 1)].utf8))
    }
    defer { CartesiaTTSMockURLProtocol.requestHandler = nil }

    let api = CartesiaTTSAPI(session: Self.makeMockSession())
    let voices = try await api.listVoices(apiKey: "sk_car_test")

    XCTAssertEqual(voices.map(\.id), ["a", "b"])
    XCTAssertEqual(voices.first?.providerVoiceID, "cartesia/a")
  }

  // MARK: - Helpers

  private func recordSynthesisRequest() async throws -> URLRequest {
    CartesiaTTSMockURLProtocol.requestHandler = { request in
      (Self.response(for: request, statusCode: 200), Data("RIFFfake".utf8))
    }
    defer { CartesiaTTSMockURLProtocol.requestHandler = nil }

    let api = CartesiaTTSAPI(session: Self.makeMockSession())
    _ = try await api.synthesize(
      transcript: "Hello there",
      apiKey: "sk_car_test",
      request: CartesiaTTSRequest(
        voiceID: CartesiaTTSCatalog.defaultVoice.providerVoiceID,
        outputFormat: .wav(sampleRate: 24_000),
        languageIdentifier: nil,
        content: "Hello there"
      )
    )
    return try XCTUnwrap(CartesiaTTSMockURLProtocol.lastRequest)
  }

  private func recordSynthesisBody() async throws -> [String: Any] {
    let request = try await recordSynthesisRequest()
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  private static func makeMockSession() -> URLSession {
    CartesiaTTSMockURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CartesiaTTSMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url ?? CartesiaTTSAPI.bytesEndpoint,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
  }
}

/// Covers the pure mapping layer: provider wiring, output formats, speed
/// clamping, language/locale resolution and error classification.
final class CartesiaTTSMappingTests: XCTestCase {
  // MARK: - Provider wiring

  func testCartesiaProvider_sharesItsTranscriptionCredential() {
    XCTAssertEqual(TTSProvider.cartesia.apiKeyIdentifier, "cartesia.apiKey")
    XCTAssertTrue(TTSProvider.cartesia.sharesTranscriptionCredential)
    XCTAssertTrue(TTSProvider.cartesia.requiresAPIKey)
    XCTAssertEqual(TTSProvider.cartesia.displayName, "Cartesia Sonic")
  }

  func testEveryCartesiaVoice_routesBackToTheCartesiaProvider() {
    XCTAssertFalse(VoiceCatalog.cartesiaVoices.isEmpty)
    for voice in VoiceCatalog.cartesiaVoices {
      XCTAssertEqual(TTSProvider.from(voiceID: voice.id), .cartesia)
      XCTAssertNotNil(VoiceCatalog.voice(forID: voice.id))
    }
  }

  func testMacVoiceProjection_matchesEverySharedCartesiaVoice() {
    XCTAssertEqual(
      Set(VoiceCatalog.cartesiaVoices.map(\.id)),
      Set(CartesiaTTSCatalog.voices.map(\.providerVoiceID))
    )
  }

  func testCartesiaVoiceIDs_resolveToTheCartesiaAPIKey() {
    let requirement = ModelCredentialResolver.requirement(
      for: CartesiaTTSCatalog.defaultVoice.providerVoiceID,
      purpose: .voiceOutput
    )

    XCTAssertEqual(requirement, .apiKey(identifier: "cartesia.apiKey", providerName: "Cartesia"))
  }

  // MARK: - Voice identifiers and output formats

  func testRequest_stripsTheRoutingPrefixFromTheStoredVoiceIdentifier() {
    let request = CartesiaTTSRequest(
      voiceID: "cartesia/ef191366-f52f-447a-a398-ed8c0f2943a1",
      outputFormat: .wav(sampleRate: 24_000),
      languageIdentifier: nil
    )

    XCTAssertEqual(request.voiceID, "ef191366-f52f-447a-a398-ed8c0f2943a1")
  }

  func testMP3Format_sendsBitRateAndNoEncoding() {
    let object = CartesiaTTSOutputFormat.mp3(sampleRate: 44_100).jsonObject

    XCTAssertEqual(object["container"] as? String, "mp3")
    XCTAssertEqual(object["sample_rate"] as? Int, 44_100)
    XCTAssertEqual(object["bit_rate"] as? Int, 128_000)
    XCTAssertNil(object["encoding"])
  }

  func testAACPreference_fallsBackToMP3BecauseCartesiaHasNoAACContainer() {
    XCTAssertEqual(CartesiaTTSClient.effectiveFormat(for: .m4a), .mp3)
    XCTAssertEqual(CartesiaTTSClient.outputFormat(format: .m4a, quality: .high).container, .mp3)
  }

  func testQualityTiers_mapOntoSupportedSampleRates() {
    XCTAssertEqual(CartesiaTTSClient.sampleRate(for: .standard), 16_000)
    XCTAssertEqual(CartesiaTTSClient.sampleRate(for: .high), 24_000)
    XCTAssertEqual(CartesiaTTSClient.sampleRate(for: .highest), 48_000)
    for quality in TTSQuality.allCases {
      XCTAssertTrue(
        CartesiaTTSAPI.supportedSampleRates.contains(CartesiaTTSClient.sampleRate(for: quality))
      )
    }
  }

  func testUnsupportedSampleRate_snapsOntoTheNearestSupportedValue() {
    XCTAssertEqual(CartesiaTTSOutputFormat.wav(sampleRate: 22_000).sampleRate, 22_050)
    XCTAssertEqual(CartesiaTTSOutputFormat.wav(sampleRate: 96_000).sampleRate, 48_000)
  }

  // MARK: - Speed clamping

  func testSpeed_isClampedIntoTheRangeCartesiaAccepts() {
    XCTAssertEqual(makeRequest(speed: 2.0).speed, 1.5, accuracy: 0.0001)
    XCTAssertEqual(makeRequest(speed: 0.5).speed, 0.6, accuracy: 0.0001)
    XCTAssertEqual(makeRequest(speed: 1.2).speed, 1.2, accuracy: 0.0001)
  }

  func testSpeed_travelsInGenerationConfig() throws {
    let body = makeRequest(speed: 3.0).jsonBody(transcript: "hi")
    let generationConfig = try XCTUnwrap(body["generation_config"] as? [String: Any])

    XCTAssertEqual(generationConfig["speed"] as? Double, 1.5)
  }

  // MARK: - Language and locale mapping

  func testRegionalLanguageChoice_becomesALocaleOnSonic36() {
    let request = makeRequest(languageIdentifier: "en_GB")
    let body = request.jsonBody(transcript: "hi")

    XCTAssertEqual(request.locale, "en-GB")
    XCTAssertNil(request.language)
    XCTAssertEqual(body["locale"] as? String, "en-GB")
    XCTAssertNil(body["language"])
  }

  func testRegionalLanguageChoice_fallsBackToABaseLanguageOnOlderModels() {
    let request = CartesiaTTSRequest(
      model: .sonic3,
      voiceID: CartesiaTTSCatalog.defaultVoice.id,
      outputFormat: .wav(sampleRate: 24_000),
      languageIdentifier: "pt_BR"
    )
    let body = request.jsonBody(transcript: "olá")

    XCTAssertNil(request.locale)
    XCTAssertEqual(request.language, "pt")
    XCTAssertEqual(body["language"] as? String, "pt")
    XCTAssertNil(body["locale"])
  }

  func testAutomaticLanguage_resolvesToABaseCodeAndNeverALocale() {
    let request = makeRequest(languageIdentifier: "automatic")

    XCTAssertNil(request.locale)
    XCTAssertEqual(request.language?.count, 2)
  }

  // MARK: - Error mapping

  func testUnauthorizedResponse_reportsAMissingKeyRatherThanAGenericFailure() {
    for statusCode in [401, 403] {
      let apiError = CartesiaTTSAPI.error(from: Data("{}".utf8), statusCode: statusCode)
      guard case .apiKeyMissing(let provider) = CartesiaTTSClient.ttsError(for: apiError) else {
        return XCTFail("Expected apiKeyMissing for HTTP \(statusCode)")
      }
      XCTAssertEqual(provider, .cartesia)
    }
  }

  func testPaymentRequiredResponse_reportsExhaustedCredits() throws {
    let apiError = CartesiaTTSAPI.error(
      from: Data(#"{"error":"out of credits"}"#.utf8),
      statusCode: 402
    )
    XCTAssertEqual(apiError, .quotaExceeded(message: "out of credits"))

    let message = try synthesisFailureMessage(CartesiaTTSClient.ttsError(for: apiError))
    XCTAssertTrue(message.contains("credits exhausted"), message)
    XCTAssertTrue(message.contains("out of credits"), message)
  }

  func testTooManyRequestsResponse_reportsTheRateLimit() throws {
    let apiError = CartesiaTTSAPI.error(from: Data("{}".utf8), statusCode: 429)
    XCTAssertEqual(apiError, .rateLimited(message: "Unknown Cartesia error"))

    let message = try synthesisFailureMessage(CartesiaTTSClient.ttsError(for: apiError))
    XCTAssertTrue(message.contains("rate limit"), message)
  }

  func testOtherFailures_reportTheStatusCode() throws {
    let apiError = CartesiaTTSAPI.error(from: Data(#"{"message":"boom"}"#.utf8), statusCode: 500)
    let message = try synthesisFailureMessage(CartesiaTTSClient.ttsError(for: apiError))

    XCTAssertTrue(message.contains("HTTP 500"), message)
    XCTAssertTrue(message.contains("boom"), message)
  }

  func testUnparseableErrorBody_isNotEchoedBackToTheUser() {
    let error = CartesiaTTSAPI.error(from: Data("sk_car_leaked".utf8), statusCode: 500)

    XCTAssertEqual(error, .httpError(statusCode: 500, message: "Unknown Cartesia error"))
  }

  // MARK: - Helpers

  private func makeRequest(
    speed: Double = 1.0,
    languageIdentifier: String? = nil
  ) -> CartesiaTTSRequest {
    CartesiaTTSRequest(
      voiceID: CartesiaTTSCatalog.defaultVoice.providerVoiceID,
      outputFormat: .wav(sampleRate: 24_000),
      languageIdentifier: languageIdentifier,
      content: "Hello there",
      speed: speed
    )
  }

  private func synthesisFailureMessage(
    _ error: TTSError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> String {
    guard case .synthesisFailure(let message) = error else {
      XCTFail("Expected synthesisFailure, got \(error)", file: file, line: line)
      throw XCTSkip("Not a synthesis failure")
    }
    return message
  }
}
