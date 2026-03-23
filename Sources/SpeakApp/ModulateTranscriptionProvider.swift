// swiftlint:disable file_length
import AVFoundation
import Foundation
import SpeakCore
import os.log

struct ModulateFeatureConfiguration: Equatable, Sendable {
  let speakerDiarization: Bool
  let emotionSignal: Bool
  let accentSignal: Bool
  let piiPhiTagging: Bool

  init(
    speakerDiarization: Bool,
    emotionSignal: Bool,
    accentSignal: Bool,
    piiPhiTagging: Bool
  ) {
    self.speakerDiarization = speakerDiarization
    self.emotionSignal = emotionSignal
    self.accentSignal = accentSignal
    self.piiPhiTagging = piiPhiTagging
  }

  init(defaults: UserDefaults) {
    speakerDiarization =
      defaults.object(forKey: AppSettings.DefaultsKey.modulateSpeakerDiarization.rawValue) as? Bool
      ?? true
    emotionSignal =
      defaults.object(forKey: AppSettings.DefaultsKey.modulateEmotionSignal.rawValue) as? Bool
      ?? false
    accentSignal =
      defaults.object(forKey: AppSettings.DefaultsKey.modulateAccentSignal.rawValue) as? Bool
      ?? false
    piiPhiTagging =
      defaults.object(forKey: AppSettings.DefaultsKey.modulatePIIPhiTagging.rawValue) as? Bool
      ?? false
  }

  var queryItems: [URLQueryItem] {
    [
      URLQueryItem(name: "speaker_diarization", value: boolString(speakerDiarization)),
      URLQueryItem(name: "emotion_signal", value: boolString(emotionSignal)),
      URLQueryItem(name: "accent_signal", value: boolString(accentSignal)),
      URLQueryItem(name: "pii_phi_tagging", value: boolString(piiPhiTagging))
    ]
  }

  var multipartFields: [(String, String)] {
    [
      ("speaker_diarization", boolString(speakerDiarization)),
      ("emotion_signal", boolString(emotionSignal)),
      ("accent_signal", boolString(accentSignal)),
      ("pii_phi_tagging", boolString(piiPhiTagging))
    ]
  }

  func formattedTranscript(from utterances: [ModulateUtterance], fallbackText: String) -> String {
    guard shouldLabelSpeakers(in: utterances) else { return fallbackText }
    return utterances.map { "Speaker \($0.speaker): \($0.text)" }.joined(separator: "\n")
  }

  func segmentText(for utterance: ModulateUtterance, within utterances: [ModulateUtterance]) -> String {
    if shouldLabelSpeakers(in: utterances) && utterance.speaker > 0 {
      return "Speaker \(utterance.speaker): \(utterance.text)"
    }
    return utterance.text
  }

  private func shouldLabelSpeakers(in utterances: [ModulateUtterance]) -> Bool {
    speakerDiarization && Set(utterances.map(\.speaker)).count > 1
  }

  private func boolString(_ value: Bool) -> String {
    value ? "true" : "false"
  }
}

final class ModulateLiveTranscriber: @unchecked Sendable {
  private let apiKey: String
  private let sampleRate: Int
  private let featureConfiguration: ModulateFeatureConfiguration
  private let session: URLSession
  private let bufferPool: AudioBufferPool
  private let logger = Logger(subsystem: "com.speak.app", category: "ModulateLiveTranscriber")
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
    session: URLSession = .shared,
    bufferPool: AudioBufferPool = AudioBufferPool(poolSize: 10, bufferSize: 4096)
  ) {
    self.apiKey = apiKey
    self.sampleRate = sampleRate
    self.featureConfiguration = featureConfiguration
    self.session = session
    self.bufferPool = bufferPool
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

    var buffer = bufferPool.checkout()
    let shouldPrefixHeader = withStateLock { () -> Bool in
      if hasSentWAVHeader { return false }
      hasSentWAVHeader = true
      return true
    }
    if shouldPrefixHeader {
      buffer.append(Self.makeStreamingWAVHeader(sampleRate: sampleRate))
    }
    buffer.append(audioData)

    let dataToSend = buffer
    let message = URLSessionWebSocketTask.Message.data(dataToSend)
    let sendGroup = pendingSendGroup
    sendGroup.enter()

    webSocketTask.send(message) { [weak self] error in
      defer { sendGroup.leave() }
      guard let self else { return }
      var returnBuffer = buffer
      self.bufferPool.returnBuffer(&returnBuffer)

      if let error {
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
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
      if self.shouldIgnoreSocketError(error) { return }
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
    bufferPool.logMetrics()
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
        if self.isStoppingState() || self.shouldIgnoreSocketError(error) { return }
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

// swiftlint:disable type_body_length
struct ModulateTranscriptionProvider: TranscriptionProvider {
  let metadata = TranscriptionProviderMetadata(
    id: "modulate",
    displayName: "Modulate",
    systemImage: "waveform.badge.magnifyingglass",
    tintColor: "teal",
    website: "https://www.modulate-developer-apis.com/web/docs.html"
  )

  private let baseURL = URL(string: "https://modulate-developer-apis.com")!
  private let session: URLSession
  private let defaultsSuiteName: String?
  private let bufferPool: AudioBufferPool

  init(
    session: URLSession = .shared,
    defaults: UserDefaults = .standard,
    bufferPool: AudioBufferPool? = nil
  ) {
    self.session = session
    self.defaultsSuiteName = Self.defaultsSuiteName(for: defaults)
    self.bufferPool = bufferPool ?? AudioBufferPool(poolSize: 10, bufferSize: 8192)
  }

  func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let featureConfiguration = ModulateFeatureConfiguration(defaults: currentDefaults())
    let endpoint = endpointURL(for: model)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

    let audioData = try Data(contentsOf: url)
    var body = Data()
    body.appendFileField(
      named: "upload_file",
      filename: url.lastPathComponent,
      mimeType: mimeType(for: url),
      fileData: audioData,
      boundary: boundary
    )

    if usesFeatureFlags(for: model) {
      for (name, value) in featureConfiguration.multipartFields {
        body.appendFormField(named: name, value: value, boundary: boundary)
      }
    }

    body.appendString("--\(boundary)--\r\n")
    request.httpBody = body

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionProviderError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw TranscriptionProviderError.httpError(http.statusCode, body)
    }

    if isEnglishFastModel(model) {
      let decoded = try JSONDecoder().decode(ModulateEnglishFastBatchResponse.self, from: data)
      return buildEnglishFastResult(response: decoded, model: model, payload: data)
    }

    let decoded = try JSONDecoder().decode(ModulateBatchResponse.self, from: data)
    return buildBatchResult(
      response: decoded,
      model: model,
      payload: data,
      featureConfiguration: featureConfiguration
    )
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    let request = makeValidationRequest(apiKey: trimmed)

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Received a non-HTTP response", debug: debugSnapshot(request: request))
      }

      let debug = debugSnapshot(request: request, response: http, data: data)
      let detail = parseValidationDetail(from: data)

      switch http.statusCode {
      case 200..<300:
        return .success(message: "Modulate API key validated", debug: debug)
      case 400, 422:
        return .success(
          message: "Modulate API key accepted, but the validation audio payload was rejected.",
          debug: debug
        )
      case 401:
        return .failure(message: detail ?? "Invalid API key.", debug: debug)
      case 403:
        if detail?.localizedCaseInsensitiveContains("invalid_api_key") == true {
          return .failure(message: "Invalid API key.", debug: debug)
        }
        return .failure(
          message: detail ?? "This Modulate model is not enabled for your organisation.",
          debug: debug
        )
      case 429:
        return .success(
          message: "Modulate API key validated, but the current quota or concurrency limit is exhausted.",
          debug: debug
        )
      default:
        return .failure(
          message: "HTTP \(http.statusCode) while validating key",
          debug: debug
        )
      }
    } catch {
      return .failure(
        message: "Validation failed: \(error.localizedDescription)",
        debug: debugSnapshot(request: request, error: error)
      )
    }
  }

  func requiresAPIKey(for model: String) -> Bool {
    true
  }

  func supportedModels() -> [ModelCatalog.Option] {
    [
      ModelCatalog.Option(
        id: "modulate/velma-2-stt-batch",
        displayName: "Velma-2 STT Batch",
        description: "Multilingual batch transcription with diarization and signal detection."
      ),
      ModelCatalog.Option(
        id: "modulate/velma-2-stt-batch-english-vfast",
        displayName: "Velma-2 STT Batch - English Fast",
        description: "Fast English-only batch transcription."
      )
    ]
  }

  func createLiveTranscriber(
    apiKey: String,
    sampleRate: Int = 16_000,
    featureConfiguration: ModulateFeatureConfiguration
  ) -> ModulateLiveTranscriber {
      ModulateLiveTranscriber(
        apiKey: apiKey,
        sampleRate: sampleRate,
        featureConfiguration: featureConfiguration,
        session: session,
        bufferPool: bufferPool
      )
  }

  private func endpointURL(for model: String) -> URL {
    if isEnglishFastModel(model) {
      return baseURL.appendingPathComponent("api/velma-2-stt-batch-english-vfast")
    }
    return baseURL.appendingPathComponent("api/velma-2-stt-batch")
  }

  private func isEnglishFastModel(_ model: String) -> Bool {
    model.hasSuffix("velma-2-stt-batch-english-vfast")
  }

  private func usesFeatureFlags(for model: String) -> Bool {
    !isEnglishFastModel(model)
  }

  private func mimeType(for url: URL) -> String {
    let mimeTypes = [
      "aac": "audio/aac",
      "aiff": "audio/aiff",
      "aif": "audio/aiff",
      "flac": "audio/flac",
      "mov": "video/quicktime",
      "mp3": "audio/mpeg",
      "mp4": "audio/mp4",
      "m4a": "audio/mp4",
      "ogg": "audio/ogg",
      "opus": "audio/opus",
      "wav": "audio/wav",
      "webm": "audio/webm"
    ]
    return mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
  }

  private func buildBatchResult(
    response: ModulateBatchResponse,
    model: String,
    payload: Data,
    featureConfiguration: ModulateFeatureConfiguration
  ) -> TranscriptionResult {
    let duration = TimeInterval(response.durationMs) / 1000
    let utterances = response.utterances
    let segments = response.utterances.map { utterance in
      TranscriptionSegment(
        startTime: TimeInterval(utterance.startMs) / 1000,
        endTime: TimeInterval(utterance.startMs + utterance.durationMs) / 1000,
        text: featureConfiguration.segmentText(for: utterance, within: utterances)
      )
    }
    let text = featureConfiguration.formattedTranscript(
      from: utterances,
      fallbackText: response.text
    )

    return TranscriptionResult(
      text: text,
      segments: segments,
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: estimatedCost(durationSeconds: duration, model: model),
      rawPayload: String(data: payload, encoding: .utf8),
      debugInfo: nil
    )
  }

  private func buildEnglishFastResult(
    response: ModulateEnglishFastBatchResponse,
    model: String,
    payload: Data
  ) -> TranscriptionResult {
    let duration = TimeInterval(response.durationMs) / 1000
    return TranscriptionResult(
      text: response.text,
      segments: [TranscriptionSegment(startTime: 0, endTime: duration, text: response.text)],
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: estimatedCost(durationSeconds: duration, model: model),
      rawPayload: String(data: payload, encoding: .utf8),
      debugInfo: nil
    )
  }

  private func estimatedCost(durationSeconds: TimeInterval, model: String) -> ChatCostBreakdown? {
    guard durationSeconds > 0 else { return nil }

    let ratePerHour: Decimal
    if isEnglishFastModel(model) {
      ratePerHour = Decimal(string: "0.025")!
    } else if model.contains("streaming") {
      ratePerHour = Decimal(string: "0.06")!
    } else {
      ratePerHour = Decimal(string: "0.03")!
    }

    let hours = Decimal(durationSeconds / 3600)
    let totalCost = hours * ratePerHour
    return ChatCostBreakdown(
      inputTokens: Int(durationSeconds),
      outputTokens: 0,
      totalCost: totalCost,
      currency: "USD"
    )
  }

  private func parseValidationDetail(from data: Data) -> String? {
    guard let error = try? JSONDecoder().decode(ModulateErrorResponse.self, from: data) else { return nil }
    return error.detail
  }

  func makeValidationRequest(apiKey: String) -> URLRequest {
    let url = baseURL.appendingPathComponent("api/velma-2-stt-batch")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

    var body = Data()
    body.appendFileField(
      named: "upload_file",
      filename: "validation.wav",
      mimeType: "audio/wav",
      fileData: Self.makeValidationAudioData(),
      boundary: boundary
    )
    body.appendString("--\(boundary)--\r\n")
    request.httpBody = body

    return request
  }

  private func debugSnapshot(
    request: URLRequest,
    response: HTTPURLResponse? = nil,
    data: Data? = nil,
    error: Error? = nil
  ) -> APIKeyValidationDebugSnapshot {
    APIKeyValidationDebugSnapshot(
      url: request.url?.absoluteString ?? "",
      method: request.httpMethod ?? "GET",
      requestHeaders: request.allHTTPHeaderFields ?? [:],
      requestBody: request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
      statusCode: response?.statusCode,
      responseHeaders: response.map { headers in
        headers.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
          guard let key = entry.key as? String else { return }
          partialResult[key] = String(describing: entry.value)
        }
      } ?? [:],
      responseBody: data.flatMap { String(data: $0, encoding: .utf8) },
      errorDescription: error?.localizedDescription
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

  private static func makeValidationAudioData(sampleRate: Int = 16_000, durationMs: Int = 250) -> Data {
    let sampleCount = sampleRate * durationMs / 1000
    let pcmData = Data(count: sampleCount * MemoryLayout<Int16>.size)
    let byteRate = sampleRate * MemoryLayout<Int16>.size
    let chunkSize = 36 + pcmData.count
    let bitsPerSample: UInt16 = 16
    let blockAlign: UInt16 = UInt16(MemoryLayout<Int16>.size)

    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    data.append(Self.littleEndianUInt32(UInt32(chunkSize)))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    data.append(Self.littleEndianUInt32(16))
    data.append(Self.littleEndianUInt16(1))
    data.append(Self.littleEndianUInt16(1))
    data.append(Self.littleEndianUInt32(UInt32(sampleRate)))
    data.append(Self.littleEndianUInt32(UInt32(byteRate)))
    data.append(Self.littleEndianUInt16(blockAlign))
    data.append(Self.littleEndianUInt16(bitsPerSample))
    data.append("data".data(using: .ascii)!)
    data.append(Self.littleEndianUInt32(UInt32(pcmData.count)))
    data.append(pcmData)
    return data
  }

  private static func littleEndianUInt16(_ value: UInt16) -> Data {
    var littleEndian = value.littleEndian
    return Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size)
  }

  private static func littleEndianUInt32(_ value: UInt32) -> Data {
    var littleEndian = value.littleEndian
    return Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
  }
}
// swiftlint:enable type_body_length

struct ModulateUtterance: Codable, Equatable, Sendable {
  let utteranceUUID: UUID?
  let text: String
  let startMs: Int
  let durationMs: Int
  let speaker: Int
  let language: String
  let emotion: String?
  let accent: String?

  enum CodingKeys: String, CodingKey {
    case utteranceUUID = "utterance_uuid"
    case text
    case startMs = "start_ms"
    case durationMs = "duration_ms"
    case speaker
    case language
    case emotion
    case accent
  }
}

private struct ModulateBatchResponse: Decodable {
  let text: String
  let durationMs: Int
  let utterances: [ModulateUtterance]

  enum CodingKeys: String, CodingKey {
    case text
    case durationMs = "duration_ms"
    case utterances
  }
}

private struct ModulateEnglishFastBatchResponse: Decodable {
  let text: String
  let durationMs: Int

  enum CodingKeys: String, CodingKey {
    case text
    case durationMs = "duration_ms"
  }
}

private struct ModulateErrorResponse: Decodable {
  let detail: String
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
// swiftlint:enable file_length
