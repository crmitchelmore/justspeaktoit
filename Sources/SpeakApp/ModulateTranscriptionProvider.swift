import AVFoundation
import Foundation
import SpeakCore
import os.log

typealias ModulateFeatureConfiguration = ModulateTranscriptionFeatures
typealias ModulateUtterance = ModulateBatchUtterance

extension ModulateTranscriptionFeatures {
  init(defaults: UserDefaults) {
    let fallback = Self()
    self.init(
      speakerDiarization: defaults.object(forKey: AppSettings.DefaultsKey.modulateSpeakerDiarization.rawValue) as? Bool
        ?? fallback.speakerDiarization,
      emotionSignal: defaults.object(forKey: AppSettings.DefaultsKey.modulateEmotionSignal.rawValue) as? Bool
        ?? fallback.emotionSignal,
      accentSignal: defaults.object(forKey: AppSettings.DefaultsKey.modulateAccentSignal.rawValue) as? Bool
        ?? fallback.accentSignal,
      piiPhiTagging: defaults.object(forKey: AppSettings.DefaultsKey.modulatePIIPhiTagging.rawValue) as? Bool
        ?? fallback.piiPhiTagging
    )
  }
}

final class ModulateLiveTranscriber: @unchecked Sendable {
  private let apiKey: String
  private let sampleRate: Int
  private let featureConfiguration: ModulateFeatureConfiguration
  private let session: URLSession
  private let logger = SpeakLogger.logger(category: "ModulateLiveTranscriber")
  private let stateLock = NSLock()
  private let pendingSendGroup = DispatchGroup()

  private var webSocketTask: URLSessionWebSocketTask?
  private var onUtterance: ((ModulateUtterance) -> Void)?
  private var onDone: ((Int) -> Void)?
  private var onError: ((Error) -> Void)?
  private var isStopping: Bool = false
  private var hasSentWAVHeader: Bool = false
  private var hasSignalledEndOfStream: Bool = false

  init(
    apiKey: String,
    sampleRate: Int = 16_000,
    featureConfiguration: ModulateFeatureConfiguration,
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.sampleRate = sampleRate
    self.featureConfiguration = featureConfiguration
    self.session = session
  }

  func start(
    onUtterance: @escaping (ModulateUtterance) -> Void,
    onDone: @escaping (Int) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    let url = makeWebSocketURL()
    var request = URLRequest(url: url)
    request.timeoutInterval = 30

    let task = session.webSocketTask(with: request)
    let shouldReceive = withStateLock { () -> Bool in
      isStopping = false
      hasSentWAVHeader = false
      hasSignalledEndOfStream = false
      self.onUtterance = onUtterance
      self.onDone = onDone
      self.onError = onError
      webSocketTask = task
      task.resume()
      return true
    }
    guard shouldReceive else { return }

    logger.info("Modulate WebSocket connection started")
    receiveMessages()
  }

  func sendAudio(_ audioData: Data) {
    guard let webSocketTask = currentWebSocketTask(), webSocketTask.state == .running else { return }

    let shouldPrefixHeader = withStateLock { () -> Bool in
      if hasSentWAVHeader { return false }
      hasSentWAVHeader = true
      return true
    }

    // Send the caller's `Data` straight through (only the first frame needs a
    // new buffer for the WAV header). Copying every chunk into a pooled buffer
    // only to hand that buffer back while the send is still in flight forced a
    // copy-on-write (plus a memset) per chunk, because `returnBuffer` zeroes
    // storage the queued message still references.
    let dataToSend: Data
    if shouldPrefixHeader {
      var framed = Self.makeStreamingWAVHeader(sampleRate: sampleRate)
      framed.append(audioData)
      dataToSend = framed
    } else {
      dataToSend = audioData
    }

    let sendGroup = pendingSendGroup
    sendGroup.enter()

    webSocketTask.send(.data(dataToSend)) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }

      if let error {
        if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
        self.logger.error("Failed to send Modulate audio: \(error.localizedDescription)")
        self.currentOnError()?(error)
      }
    }
  }

  func signalEndOfStream() {
    guard let task = currentWebSocketTask(), task.state == .running else { return }
    let shouldSignal = withStateLock { () -> Bool in
      guard !hasSignalledEndOfStream else { return false }
      hasSignalledEndOfStream = true
      isStopping = true
      return true
    }
    guard shouldSignal else { return }

    let sendGroup = pendingSendGroup
    sendGroup.enter()
    task.send(.string("")) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self, let error else { return }
      if WebSocketErrorFilter.shouldIgnore(error) { return }
      self.logger.error("Failed to send Modulate end-of-stream: \(error.localizedDescription)")
      self.currentOnError()?(error)
    }
  }

  func cancel() {
    let task = withStateLock { () -> URLSessionWebSocketTask? in
      isStopping = true
      let current = webSocketTask
      webSocketTask = nil
      return current
    }
    task?.cancel(with: .normalClosure, reason: nil)
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

  private func receiveMessages() {
    guard let task = currentWebSocketTask() else { return }
    task.receive { [weak self] result in
      guard let self else { return }

      switch result {
      case .success(let message):
        self.handleMessage(message)
        if !self.isStoppingState() || self.currentWebSocketTask() != nil {
          self.receiveMessages()
        }
      case .failure(let error):
        if self.isStoppingState() || WebSocketErrorFilter.shouldIgnore(error) { return }
        self.logger.error("Modulate WebSocket receive error: \(error.localizedDescription)")
        self.currentOnError()?(error)
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    let text: String?
    switch message {
    case .string(let payload):
      text = payload
    case .data(let data):
      text = String(data: data, encoding: .utf8)
    @unknown default:
      text = nil
    }

    guard let text else { return }
    parseResponse(text)
  }

  private func parseResponse(_ json: String) {
    guard let data = json.data(using: .utf8) else { return }

    do {
      let envelope = try JSONDecoder().decode(ModulateStreamingEnvelope.self, from: data)
      switch envelope.type {
      case "utterance":
        let message = try JSONDecoder().decode(ModulateStreamingUtteranceMessage.self, from: data)
        currentOnUtterance()?(message.utterance)
      case "done":
        let message = try JSONDecoder().decode(ModulateStreamingDoneMessage.self, from: data)
        currentOnDone()?(message.durationMs)
        cancel()
      case "error":
        let message = try JSONDecoder().decode(ModulateStreamingErrorMessage.self, from: data)
        currentOnError()?(TranscriptionProviderError.httpError(500, message.error))
        cancel()
      default:
        logger.debug("Unhandled Modulate message type: \(envelope.type)")
      }
    } catch {
      logger.error("Failed to parse Modulate response: \(error.localizedDescription)")
      currentOnError()?(error)
    }
  }

  private func makeWebSocketURL() -> URL {
    var components = URLComponents(string: "wss://modulate-developer-apis.com/api/velma-2-stt-streaming")!
    components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + featureConfiguration.queryItems
    return components.url!
  }

  private func withStateLock<T>(_ block: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return block()
  }

  private func currentWebSocketTask() -> URLSessionWebSocketTask? {
    withStateLock { webSocketTask }
  }

  private func currentOnError() -> ((Error) -> Void)? {
    withStateLock { onError }
  }

  private func currentOnDone() -> ((Int) -> Void)? {
    withStateLock { onDone }
  }

  private func currentOnUtterance() -> ((ModulateUtterance) -> Void)? {
    withStateLock { onUtterance }
  }

  private func isStoppingState() -> Bool {
    withStateLock { isStopping }
  }

  private static func makeStreamingWAVHeader(sampleRate: Int) -> Data {
    var data = Data()

    func append(_ string: String) {
      data.append(string.data(using: .ascii)!)
    }

    func append(_ value: UInt16) {
      var littleEndian = value.littleEndian
      data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    func append(_ value: UInt32) {
      var littleEndian = value.littleEndian
      data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }

    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = UInt32(bitsPerSample / 8)
    let byteRate = UInt32(sampleRate) * UInt32(channels) * bytesPerSample
    let blockAlign = channels * bitsPerSample / 8

    append("RIFF")
    append(UInt32.max)
    append("WAVE")
    append("fmt ")
    append(UInt32(16))
    append(UInt16(1))
    append(channels)
    append(UInt32(sampleRate))
    append(byteRate)
    append(blockAlign)
    append(bitsPerSample)
    append("data")
    append(UInt32.max)
    return data
  }
}

struct ModulateTranscriptionProvider: TranscriptionProvider {
  private let session: URLSession
  private let defaultsSuiteName: String?
  private let multipartStaging: MultipartUploadStaging
  var metadata: TranscriptionProviderMetadata { client.metadata }

  init(
    session: URLSession = .shared, defaults: UserDefaults = .standard,
    multipartStaging: MultipartUploadStaging = .shared
  ) {
    self.session = session
    self.defaultsSuiteName = Self.defaultsSuiteName(for: defaults)
    self.multipartStaging = multipartStaging
  }

  private var client: ModulateBatchClient {
    ModulateBatchClient(
      session: session, features: ModulateFeatureConfiguration(defaults: currentDefaults()),
      multipartStaging: multipartStaging.sharedStore
    )
  }

  func transcribeFile(
    at url: URL, apiKey: String, model: String, language: String?
  ) async throws -> TranscriptionResult {
    try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await client.validateAPIKey(key) }
  func requiresAPIKey(for model: String) -> Bool { client.requiresAPIKey(for: model) }
  func supportedModels() -> [ModelCatalog.Option] { client.supportedModels() }
  func makeValidationRequest(apiKey: String) -> URLRequest { client.makeValidationRequest(apiKey: apiKey) }

  func createLiveTranscriber(
    apiKey: String, sampleRate: Int = 16_000, featureConfiguration: ModulateFeatureConfiguration
  ) -> ModulateLiveTranscriber {
    ModulateLiveTranscriber(
      apiKey: apiKey, sampleRate: sampleRate, featureConfiguration: featureConfiguration, session: session
    )
  }

  private func currentDefaults() -> UserDefaults {
    guard let defaultsSuiteName, let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
      return .standard
    }
    return defaults
  }

  private static func defaultsSuiteName(for defaults: UserDefaults) -> String? {
    let standardDomain = Bundle.main.bundleIdentifier ?? "com.github.speakapp"
    let argumentDomain = "NSArgumentDomain"
    let registrationDomain = "NSRegistrationDomain"
    return defaults
      .volatileDomainNames
      .first(where: { name in name != argumentDomain && name != registrationDomain && name != standardDomain })
  }

}

private struct ModulateStreamingEnvelope: Decodable {
  let type: String
}

private struct ModulateStreamingUtteranceMessage: Decodable {
  let type: String
  let utterance: ModulateUtterance
}

private struct ModulateStreamingDoneMessage: Decodable {
  let type: String
  let durationMs: Int

  enum CodingKeys: String, CodingKey {
    case type
    case durationMs = "duration_ms"
  }
}

private struct ModulateStreamingErrorMessage: Decodable {
  let type: String
  let error: String
}
