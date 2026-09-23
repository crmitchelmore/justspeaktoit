import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ModulateBatchClient: TranscriptionProvider {
  public let metadata = TranscriptionProviderMetadata(
    id: "modulate",
    displayName: "Modulate",
    systemImage: "waveform.badge.magnifyingglass",
    tintColor: "teal",
    website: "https://www.modulate-developer-apis.com/web/docs.html"
  )

  let baseURL = URL(string: "https://modulate-developer-apis.com")!
  let session: URLSession
  private let featureConfiguration: ModulateTranscriptionFeatures
  private let multipartStaging: SharedMultipartUploadStaging

  public init(
    session: URLSession = .shared,
    features: ModulateTranscriptionFeatures = .init(),
    multipartStaging: SharedMultipartUploadStaging
  ) {
    self.session = session
    self.featureConfiguration = features
    self.multipartStaging = multipartStaging
  }

  public func transcribeFile(
    at url: URL,
    apiKey: String,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
    try Task.checkCancellation()
    let endpoint = endpointURL(for: model)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

    let fields = usesFeatureFlags(for: model) ? featureConfiguration.multipartFields : []
    let upload = try multipartStaging.writeMultipart(
      sourceURL: url, providerID: metadata.id, boundary: boundary, fields: [],
      mimeType: mimeType(for: url), fileField: "upload_file", trailingFields: fields
    )
    defer { multipartStaging.removeUploadBodyFile(at: upload) }
    let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
    let (data, response) = try await session.upload(for: request, fromFile: upload, delegate: redirects)
    try Task.checkCancellation()
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

  public func requiresAPIKey(for model: String) -> Bool {
    true
  }

  public func supportedModels() -> [ModelCatalog.Option] {
    ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
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
    featureConfiguration: ModulateTranscriptionFeatures
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

}

private struct ModulateBatchResponse: Decodable {
  let text: String
  let durationMs: Int
  let utterances: [ModulateBatchUtterance]

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
