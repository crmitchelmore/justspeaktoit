// swiftlint:disable file_length
import Foundation
import os.log
import SpeakCore

enum CartesiaLiveError: LocalizedError {
  case missingAPIKey
  case invalidURLComponents
  case invalidAPIKey
  case connectionFailed
  case batchNotSupported

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Cartesia API key is missing. Please add it in Settings -> Cartesia."
    case .invalidURLComponents:
      return "Failed to construct Cartesia WebSocket URL."
    case .invalidAPIKey:
      return "Cartesia API key is invalid. Check your key in Settings -> Cartesia."
    case .connectionFailed:
      return "Failed to establish WebSocket connection to Cartesia."
    case .batchNotSupported:
      return "Cartesia Ink-2 is currently only available for live streaming in Speak."
    }
  }
}

struct CartesiaTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "cartesia",
    displayName: "Cartesia",
    systemImage: "waveform.and.person.filled",
    tintColor: "purple",
    website: "https://cartesia.ai"
  )

  private let session: URLSession
  private let validationBaseURL = URL(string: "https://api.cartesia.ai")!

  init(session: URLSession = .shared) {
    self.session = session
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    _ = (url, apiKey, model, language)
    throw CartesiaLiveError.batchNotSupported
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "Empty API key")
    }

    let url = validationBaseURL.appendingPathComponent("voices")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    request.setValue(CartesiaLiveTranscriber.apiVersion, forHTTPHeaderField: "Cartesia-Version")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      let debug = debugSnapshot(request: request, response: http, data: data)
      switch http.statusCode {
      case 200..<300:
        return .success(message: "Cartesia API key validated", debug: debug)
      case 401, 403:
        return .failure(message: "Cartesia rejected the key (HTTP \(http.statusCode))", debug: debug)
      default:
        return .failure(message: "HTTP \(http.statusCode) while validating key", debug: debug)
      }
    } catch {
      return .failure(message: "Validation failed: \(error.localizedDescription)")
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    [
      ModelCatalog.Option(
        id: "cartesia/ink-2-streaming",
        displayName: "Ink-2 Streaming",
        description: "Cartesia Ink-2 real-time English STT with built-in turn detection."
      )
    ]
  }

  func createLiveTranscriber(
    apiKey: String,
    model: String = "ink-2",
    sampleRate: Int = 16_000
  ) -> CartesiaLiveTranscriber {
    CartesiaLiveTranscriber(apiKey: apiKey, model: model, sampleRate: sampleRate, session: session)
  }

  private func debugSnapshot(
    request: URLRequest,
    response: HTTPURLResponse,
    data: Data
  ) -> APIKeyValidationDebugSnapshot {
    APIKeyValidationDebugSnapshot(
      url: request.url?.absoluteString ?? "",
      method: request.httpMethod ?? "GET",
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
      statusCode: response.statusCode,
      responseHeaders: response.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
        guard let key = entry.key as? String else { return }
        partialResult[key] = String(describing: entry.value)
      },
      responseBody: String(data: data, encoding: .utf8),
      errorDescription: nil
    )
  }
}

final class CartesiaLiveTranscriber: @unchecked Sendable {
  static let apiVersion = "2026-03-01"
  static let preferredChunkBytes = 3_200
  static let minimumChunkBytes = 1_600

  private static let host = "api.cartesia.ai"
  private static let path = "/stt/turns/websocket"

  private let apiKey: String
  private let model: String
  private let sampleRate: Int
  private let session: URLSession
  private let logger = Logger(subsystem: "com.speak.app", category: "CartesiaLiveTranscriber")
  private let stateLock = NSLock()
  private let pendingSendGroup = DispatchGroup()

  private var webSocketTask: URLSessionWebSocketTask?
  private var onTranscript: ((String, Bool) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping = false

  init(
    apiKey: String,
    model: String = "ink-2",
    sampleRate: Int = 16_000,
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.model = model
    self.sampleRate = sampleRate
    self.session = session
  }

  func start(
    onTranscript: @escaping (String, Bool) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    withStateLock {
      isStopping = false
      self.onTranscript = onTranscript
      self.onError = onError
    }
    connectWebSocket()
  }

  func sendAudio(_ audioData: Data) {
    guard let task = currentWebSocketTask(), task.state == .running else { return }
    let sendGroup = pendingSendGroup
    sendGroup.enter()
    task.send(.data(audioData)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }
      if let error {
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
        self.currentOnError()?(self.mapConnectionError(error))
      }
    }
  }

  func waitForPendingSends(timeout: TimeInterval = 1.5) async {
    let sendGroup = pendingSendGroup
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        _ = sendGroup.wait(timeout: .now() + timeout)
        continuation.resume()
      }
    }
  }

  func stop() {
    let task = withStateLock { () -> URLSessionWebSocketTask? in
      guard !isStopping else { return nil }
      isStopping = true
      return webSocketTask
    }
    guard let task else { return }
    if task.state == .running {
      task.cancel(with: .normalClosure, reason: nil)
    }
    withStateLock {
      if webSocketTask === task { webSocketTask = nil }
    }
  }

  nonisolated static func webSocketURL(model: String, sampleRate: Int) -> URL? {
    var components = URLComponents()
    components.scheme = "wss"
    components.host = host
    components.path = path
    components.queryItems = [
      URLQueryItem(name: "model", value: model),
      URLQueryItem(name: "encoding", value: "pcm_s16le"),
      URLQueryItem(name: "sample_rate", value: String(sampleRate)),
      URLQueryItem(name: "cartesia_version", value: apiVersion)
    ]
    return components.url
  }

  nonisolated static func transcriptEvent(from json: String) -> (text: String, isFinal: Bool)? {
    guard
      let data = json.data(using: .utf8),
      let response = try? JSONDecoder().decode(CartesiaTurnResponse.self, from: data)
    else {
      return nil
    }
    guard let transcript = response.transcriptText, !transcript.isEmpty else {
      return nil
    }
    return (transcript, response.type == "turn.end")
  }

  private func connectWebSocket() {
    guard let url = Self.webSocketURL(model: model, sampleRate: sampleRate) else {
      currentOnError()?(CartesiaLiveError.invalidURLComponents)
      return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")

    let task = session.webSocketTask(with: request)
    let proceed = withStateLock { () -> Bool in
      guard !isStopping else { return false }
      webSocketTask = task
      task.resume()
      return true
    }
    guard proceed else {
      task.cancel(with: .goingAway, reason: nil)
      return
    }
    logger.info("Cartesia WebSocket connecting (model=\(self.model, privacy: .public))")
    receiveMessages()
  }

  private func receiveMessages() {
    guard let task = currentWebSocketTask() else { return }
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        self.handleMessage(message)
        self.receiveMessages()
      case .failure(let error):
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
        self.currentOnError()?(self.mapConnectionError(error))
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .string(let text):
      parseResponse(text)
    case .data(let data):
      if let text = String(data: data, encoding: .utf8) {
        parseResponse(text)
      }
    @unknown default:
      break
    }
  }

  private func parseResponse(_ json: String) {
    guard let event = Self.transcriptEvent(from: json) else { return }
    currentOnTranscript()?(event.text, event.isFinal)
  }

  private func mapConnectionError(_ error: Error) -> Error {
    let nsError = error as NSError
    let description = nsError.localizedDescription.lowercased()
    if nsError.code == 401 || nsError.code == 403
      || description.contains("401") || description.contains("403")
      || description.contains("unauthorized") || description.contains("forbidden") {
      return CartesiaLiveError.invalidAPIKey
    }
    return error
  }

  private func shouldIgnoreSocketError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 { return true }
    if nsError.localizedDescription.localizedCaseInsensitiveContains("socket is not connected") {
      return true
    }
    return false
  }

  private func withStateLock<T>(_ block: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return block()
  }

  private func currentWebSocketTask() -> URLSessionWebSocketTask? {
    withStateLock { webSocketTask }
  }

  private func isStoppingState() -> Bool {
    withStateLock { isStopping }
  }

  private func currentOnTranscript() -> ((String, Bool) -> Void)? {
    withStateLock { onTranscript }
  }

  private func currentOnError() -> ((Error) -> Void)? {
    withStateLock { onError }
  }
}

private struct CartesiaTurnResponse: Decodable {
  struct Result: Decodable {
    let transcript: String?
  }

  let type: String
  let transcript: String?
  let results: [Result]?

  private enum CodingKeys: String, CodingKey {
    case type
    case transcript
    case results
  }

  var transcriptText: String? {
    if let transcript {
      return transcript
    }
    return results?.compactMap(\.transcript).first { !$0.isEmpty }
  }
}
