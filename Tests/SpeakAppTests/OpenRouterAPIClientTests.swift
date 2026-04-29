import Foundation
import XCTest

@testable import SpeakApp

@MainActor
final class OpenRouterAPIClientTests: XCTestCase {
  func testTranscribeFileUsesChatCompletionsJSONAudioInput() async throws {
    let requestObserver = OpenRouterRequestObserver()
    OpenRouterMockURLProtocol.requestHandler = { request in
      await requestObserver.store(request: request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let json = """
      {
        "choices": [
          {
            "index": 0,
            "finish_reason": "stop",
            "message": {
              "role": "assistant",
              "content": "hello world"
            }
          }
        ]
      }
      """
      return (response, Data(json.utf8))
    }
    defer {
      OpenRouterMockURLProtocol.requestHandler = nil
    }

    let client = OpenRouterAPIClient(
      secureStorage: makeSecureStorage(),
      session: makeMockSession(),
      apiKeyOverride: "test-openrouter-key"
    )
    let audioURL = try makeAudioFile(extension: "m4a", data: Data("fakeaudiodata".utf8))
    defer {
      try? FileManager.default.removeItem(at: audioURL)
    }

    _ = try? await client.transcribeFile(
      at: audioURL,
      model: "google/gemini-2.0-flash-001",
      language: "en_GB"
    )

    let capturedRequest = await requestObserver.capturedRequest()
    let capturedBody = await requestObserver.capturedBody()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(capturedBody)

    try assertRequestMetadata(request, body: body)
    try assertAudioInputPayload(body)
  }

  func testProviderRegistryDoesNotClaimOpenRouterOpenAIModel() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(
      forModel: "openai/gpt-4o-audio-preview-2024-12-17"
    )

    XCTAssertNil(provider)
  }

  func testProviderRegistryStillClaimsDedicatedOpenAIWhisperModel() async {
    let provider = await TranscriptionProviderRegistry.shared.provider(forModel: "openai/whisper-1")

    XCTAssertEqual(provider?.metadata.id, "openai")
  }

  private func assertRequestMetadata(_ request: URLRequest, body: Data) throws {
    let bodyString = String(data: body, encoding: .utf8) ?? ""

    XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openrouter-key")
    XCTAssertFalse(bodyString.hasPrefix("--Boundary-"))
  }

  private func assertAudioInputPayload(_ body: Data) throws {
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "google/gemini-2.0-flash-001")
    XCTAssertEqual(json["stream"] as? Bool, false)

    let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
    let firstMessage = try XCTUnwrap(messages.first)
    XCTAssertEqual(firstMessage["role"] as? String, "user")

    let content = try XCTUnwrap(firstMessage["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 2)
    XCTAssertEqual(content.first?["type"] as? String, "text")
    XCTAssertTrue((content.first?["text"] as? String)?.contains("en_GB") == true)

    let audioPart = try XCTUnwrap(content.last)
    XCTAssertEqual(audioPart["type"] as? String, "input_audio")
    let inputAudio = try XCTUnwrap(audioPart["input_audio"] as? [String: Any])
    XCTAssertEqual(inputAudio["format"] as? String, "m4a")
    XCTAssertEqual(inputAudio["data"] as? String, Data("fakeaudiodata".utf8).base64EncodedString())
  }

  private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeSecureStorage() -> SecureAppStorage {
    let suiteName = "OpenRouterAPIClientTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    let settings = AppSettings(defaults: defaults)
    let permissions = PermissionsManager()
    return SecureAppStorage(permissionsManager: permissions, appSettings: settings)
  }

  private func makeAudioFile(extension fileExtension: String, data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("openrouter_audio_\(UUID().uuidString).\(fileExtension)")
    try data.write(to: url)
    return url
  }
}

private typealias OpenRouterRequestHandler =
  @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)

private actor OpenRouterRequestObserver {
  private var request: URLRequest?
  private var body: Data?

  func store(request: URLRequest) {
    self.request = request
    body = request.httpBody ?? readBody(from: request.httpBodyStream)
  }

  func capturedRequest() -> URLRequest? {
    request
  }

  func capturedBody() -> Data? {
    body
  }

  private func readBody(from stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let readCount = stream.read(buffer, maxLength: bufferSize)
      if readCount < 0 {
        return nil
      }
      if readCount == 0 {
        break
      }
      data.append(buffer, count: readCount)
    }

    return data.isEmpty ? nil : data
  }
}

private final class OpenRouterMockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: OpenRouterRequestHandler?

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      XCTFail("OpenRouterMockURLProtocol.requestHandler was not set")
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
