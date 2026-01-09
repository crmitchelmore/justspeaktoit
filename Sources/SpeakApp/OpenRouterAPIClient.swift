import SpeakCore
import AVFoundation
import Foundation
import os.log

enum OpenRouterClientError: LocalizedError {
  case apiKeyMissing
  case invalidResponse
  case httpStatus(Int, String)

  var errorDescription: String? {
    switch self {
    case .apiKeyMissing:
      return "OpenRouter API key is missing."
    case .invalidResponse:
      return "The server returned an invalid response."
    case .httpStatus(let code, let body):
      return "OpenRouter responded with status \(code): \(body)"
    }
  }
}

actor OpenRouterAPIClient: StreamingChatLLMClient, BatchTranscriptionClient {
  private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
  private let session: URLSession
  private let secureStorage: SecureAppStorage
  private let logger = Logger(subsystem: "com.github.speakapp", category: "OpenRouter")
  private let apiKeyIdentifier = "openrouter.apiKey"
  private let titleHeaderValue = "SpeakApp (macOS)"
  private let refererHeaderValue = "https://github.com/speak"

  private struct ValidationAttemptResult {
    let success: Bool
    let debug: APIKeyValidationDebugSnapshot
    let message: String
  }

  private struct ValidationAttemptError: Error {
    let debug: APIKeyValidationDebugSnapshot
    let message: String
  }

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.session = session
  }

  func hasStoredAPIKey() async -> Bool {
    await secureStorage.hasSecret(identifier: apiKeyIdentifier)
  }

  func requiresRemoteAccess(for model: String) -> Bool {
    !allowsLocalFallback(for: model)
  }

  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    if let key = try? await secureStorage.secret(identifier: apiKeyIdentifier), !key.isEmpty {
      return try await performRemoteChat(
        apiKey: key,
        systemPrompt: systemPrompt,
        messages: messages,
        model: model,
        temperature: temperature
      )
    }

    return performLocalChatFallback(systemPrompt: systemPrompt, messages: messages)
  }

  nonisolated func sendChatStreaming(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let key = try await self.secureStorage.secret(identifier: self.apiKeyIdentifier)
          guard !key.isEmpty else {
            continuation.finish(throwing: OpenRouterClientError.apiKeyMissing)
            return
          }

          let url = await self.baseURL.appendingPathComponent("chat/completions")
          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
          await self.applyBrandHeaders(&request)

          let builtMessages = await self.buildMessages(systemPrompt: systemPrompt, messages: messages)
          let streamingMessages = builtMessages.map { msg in
            OpenRouterStreamingChatRequest.Message(role: msg.role, content: msg.content)
          }
          let payload = OpenRouterStreamingChatRequest(
            model: model,
            temperature: temperature,
            messages: streamingMessages,
            stream: true
          )

          request.httpBody = try JSONEncoder().encode(payload)

          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: OpenRouterClientError.invalidResponse)
            return
          }
          guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
              body += line
            }
            continuation.finish(throwing: OpenRouterClientError.httpStatus(http.statusCode, body))
            return
          }

          for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard line.hasPrefix("data: ") else { continue }

            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }

            guard let data = jsonString.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(OpenRouterStreamChunk.self, from: data),
               let delta = chunk.choices.first?.delta,
               let content = delta.content, !content.isEmpty {
              continuation.yield(content)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func transcribeFile(at url: URL, model: String, language: String?) async throws
    -> TranscriptionResult
  {
    let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawKey = try? await secureStorage.secret(identifier: apiKeyIdentifier)
    let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let key, !key.isEmpty {
      return try await performRemoteTranscription(
        apiKey: key, url: url, model: cleanedModel, language: language)
    }

    if allowsLocalFallback(for: cleanedModel) {
      return try await localTranscriptionFallback(url: url, model: cleanedModel)
    }

    throw OpenRouterClientError.apiKeyMissing
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(
        message: "API key is empty",
        debug: APIKeyValidationDebugSnapshot(
          url: "",
          method: "",
          requestHeaders: [:],
          requestBody: nil,
          statusCode: nil,
          responseHeaders: [:],
          responseBody: nil,
          errorDescription: "API key is empty"
        )
      )
    }

    var lastFailure: (message: String, debug: APIKeyValidationDebugSnapshot?) =
      ("Validation failed", nil)

    do {
      let authResult = try await validateViaAuthEndpoint(apiKey: trimmed)
      if authResult.success {
        return .success(
          message: "OpenRouter API key validated via auth endpoint",
          debug: authResult.debug
        )
      }
      lastFailure = (authResult.message, authResult.debug)
    } catch let attemptError as ValidationAttemptError {
      logger.error("API key auth validation failed: \(attemptError.message, privacy: .public)")
      lastFailure = (attemptError.message, attemptError.debug)
    } catch {
      logger.error("API key auth validation failed: \(error.localizedDescription, privacy: .public)")
      let debug = APIKeyValidationDebugSnapshot(
        url: baseURL.appendingPathComponent("auth/validate").absoluteString,
        method: "GET",
        requestHeaders: [:],
        requestBody: nil,
        statusCode: nil,
        responseHeaders: [:],
        responseBody: nil,
        errorDescription: error.localizedDescription
      )
      lastFailure = (error.localizedDescription, debug)
    }

    do {
      let chatResult = try await validateViaChat(apiKey: trimmed)
      if chatResult.success {
        return .success(
          message: "OpenRouter API key validated via models endpoint",
          debug: chatResult.debug
        )
      }
      lastFailure = (chatResult.message, chatResult.debug)
    } catch let attemptError as ValidationAttemptError {
      logger.error(
        "API key validation via chat failed: \(attemptError.message, privacy: .public)"
      )
      lastFailure = (attemptError.message, attemptError.debug)
    } catch {
      logger.error(
        "API key validation via chat failed: \(error.localizedDescription, privacy: .public)"
      )
      let debug = APIKeyValidationDebugSnapshot(
        url: baseURL.appendingPathComponent("models").absoluteString,
        method: "GET",
        requestHeaders: [:],
        requestBody: nil,
        statusCode: nil,
        responseHeaders: [:],
        responseBody: nil,
        errorDescription: error.localizedDescription
      )
      lastFailure = (error.localizedDescription, debug)
    }

    return .failure(message: lastFailure.message, debug: lastFailure.debug)
  }

  private func validateViaAuthEndpoint(apiKey: String) async throws -> ValidationAttemptResult {
    let url = baseURL.appendingPathComponent("auth/validate")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    applyBrandHeaders(&request)

    let headers = request.allHTTPHeaderFields ?? [:]

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        let debug = APIKeyValidationDebugSnapshot(
          url: url.absoluteString,
          method: request.httpMethod ?? "GET",
          requestHeaders: headers,
          requestBody: nil,
          statusCode: nil,
          responseHeaders: [:],
          responseBody: nil,
          errorDescription: OpenRouterClientError.invalidResponse.localizedDescription
        )
        throw ValidationAttemptError(
          debug: debug,
          message: OpenRouterClientError.invalidResponse.localizedDescription
        )
      }

      let responseBody = string(from: data)
      let debug = APIKeyValidationDebugSnapshot(
        url: url.absoluteString,
        method: request.httpMethod ?? "GET",
        requestHeaders: headers,
        requestBody: nil,
        statusCode: http.statusCode,
        responseHeaders: normalizedHeaders(http.allHeaderFields),
        responseBody: responseBody,
        errorDescription: http.statusCode == 200 ? nil : responseBody
      )

      if http.statusCode == 200 {
        if let payload = try? JSONDecoder().decode(OpenRouterValidationResponse.self, from: data) {
          if let valid = payload.valid {
            return ValidationAttemptResult(
              success: valid,
              debug: debug,
              message: valid ? "Validated" : "Auth validation returned invalid"
            )
          }
          if let valid = payload.data?.valid {
            return ValidationAttemptResult(
              success: valid,
              debug: debug,
              message: valid ? "Validated" : "Auth validation returned invalid"
            )
          }
        }
        return ValidationAttemptResult(
          success: true,
          debug: debug,
          message: "Validated"
        )
      }

      if http.statusCode == 401 {
        return ValidationAttemptResult(
          success: false,
          debug: debug,
          message: "Unauthorized response from auth endpoint"
        )
      }

      throw ValidationAttemptError(
        debug: debug,
        message: "Unexpected status \(http.statusCode)"
      )
    } catch let attemptError as ValidationAttemptError {
      throw attemptError
    } catch {
      let debug = APIKeyValidationDebugSnapshot(
        url: url.absoluteString,
        method: request.httpMethod ?? "GET",
        requestHeaders: headers,
        requestBody: nil,
        statusCode: nil,
        responseHeaders: [:],
        responseBody: nil,
        errorDescription: error.localizedDescription
      )
      throw ValidationAttemptError(debug: debug, message: error.localizedDescription)
    }
  }

  private func validateViaChat(apiKey: String) async throws -> ValidationAttemptResult {
    let url = baseURL.appendingPathComponent("models")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    applyBrandHeaders(&request)

    let headers = request.allHTTPHeaderFields ?? [:]

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        let debug = APIKeyValidationDebugSnapshot(
          url: url.absoluteString,
          method: request.httpMethod ?? "GET",
          requestHeaders: headers,
          requestBody: nil,
          statusCode: nil,
          responseHeaders: [:],
          responseBody: nil,
          errorDescription: OpenRouterClientError.invalidResponse.localizedDescription
        )
        throw ValidationAttemptError(
          debug: debug,
          message: OpenRouterClientError.invalidResponse.localizedDescription
        )
      }

      let responseBody = string(from: data)
      let debug = APIKeyValidationDebugSnapshot(
        url: url.absoluteString,
        method: request.httpMethod ?? "GET",
        requestHeaders: headers,
        requestBody: nil,
        statusCode: http.statusCode,
        responseHeaders: normalizedHeaders(http.allHeaderFields),
        responseBody: responseBody,
        errorDescription: (200..<300).contains(http.statusCode) ? nil : responseBody
      )

      if (200..<300).contains(http.statusCode) {
        return ValidationAttemptResult(
          success: true,
          debug: debug,
          message: "Validated"
        )
      }

      if http.statusCode == 401 {
        return ValidationAttemptResult(
          success: false,
          debug: debug,
          message: "Unauthorized response from models endpoint"
        )
      }

      throw ValidationAttemptError(
        debug: debug,
        message: "Unexpected status \(http.statusCode)"
      )
    } catch let attemptError as ValidationAttemptError {
      throw attemptError
    } catch {
      let debug = APIKeyValidationDebugSnapshot(
        url: url.absoluteString,
        method: request.httpMethod ?? "GET",
        requestHeaders: headers,
        requestBody: nil,
        statusCode: nil,
        responseHeaders: [:],
        responseBody: nil,
        errorDescription: error.localizedDescription
      )
      throw ValidationAttemptError(debug: debug, message: error.localizedDescription)
    }
  }

  private func performRemoteChat(
    apiKey: String,
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    let url = baseURL.appendingPathComponent("chat/completions")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    applyBrandHeaders(&request)

    let payload = OpenRouterChatRequest(
      model: model,
      temperature: temperature,
      messages: buildMessages(systemPrompt: systemPrompt, messages: messages)
    )

    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OpenRouterClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw OpenRouterClientError.httpStatus(http.statusCode, body)
    }

    let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
    let assistantMessages = decoded.choices.compactMap { choice in
      choice.message.map { ChatMessage(role: .assistant, content: $0.content) }
    }

    let finishReason = decoded.choices.first?.finish_reason ?? "stop"
    let cost = decoded.usage.map { usage in
      ChatCostBreakdown(
        inputTokens: usage.prompt_tokens,
        outputTokens: usage.completion_tokens,
        totalCost: Decimal(usage.prompt_tokens + usage.completion_tokens) / 1_000_000,
        currency: "USD"
      )
    }

    var conversation: [ChatMessage] = []
    if let systemPrompt {
      conversation.append(ChatMessage(role: .system, content: systemPrompt))
    }
    conversation.append(contentsOf: messages)
    conversation.append(contentsOf: assistantMessages)

    return ChatResponse(
      messages: conversation,
      finishReason: finishReason,
      cost: cost,
      rawPayload: String(data: data, encoding: .utf8)
    )
  }

  private func performRemoteTranscription(
    apiKey: String,
    url: URL,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    applyBrandHeaders(&request)

    let audioData = try Data(contentsOf: url)
    var body = Data()
    body.appendFormField(named: "model", value: model, boundary: boundary)
    if let language {
      body.appendFormField(named: "language", value: language, boundary: boundary)
    }
    body.appendFileField(
      named: "file",
      filename: url.lastPathComponent,
      mimeType: "audio/m4a",
      fileData: audioData,
      boundary: boundary
    )
    body.appendString("--\(boundary)--\r\n")
    request.httpBody = body

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OpenRouterClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "<no-body>"
      throw OpenRouterClientError.httpStatus(http.statusCode, body)
    }

    let decoded = try JSONDecoder().decode(OpenRouterTranscriptionResponse.self, from: data)
    return try await buildTranscriptionResult(
      response: decoded,
      audioURL: url,
      model: model,
      payload: data
    )
  }

  private func localTranscriptionFallback(url: URL, model: String) async throws
    -> TranscriptionResult
  {
    let asset = AVURLAsset(url: url)
    let durationTime = try await asset.load(.duration)
    let duration = durationTime.seconds
    let text = "Transcription placeholder for \(url.lastPathComponent)"
    let segment = TranscriptionSegment(startTime: 0, endTime: duration, text: text)
    return TranscriptionResult(
      text: text,
      segments: [segment],
      confidence: nil,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  private func performLocalChatFallback(systemPrompt: String?, messages: [ChatMessage])
    -> ChatResponse
  {
    let userText =
      messages.last(where: { $0.role == .user })?.content
      ?? messages.last?.content
      ?? ""
    let processed = heuristicPostProcess(text: userText)

    var conversation: [ChatMessage] = []
    if let systemPrompt {
      conversation.append(ChatMessage(role: .system, content: systemPrompt))
    }
    conversation.append(contentsOf: messages)
    conversation.append(ChatMessage(role: .assistant, content: processed))

    return ChatResponse(
      messages: conversation, finishReason: "fallback-local", cost: nil, rawPayload: nil)
  }

  private func heuristicPostProcess(text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return text }

    let collapsed =
      trimmed
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    guard !collapsed.isEmpty else { return trimmed }

    var result = collapsed
    if let first = result.first {
      let uppercaseFirst = String(first).uppercased()
      result.replaceSubrange(result.startIndex...result.startIndex, with: uppercaseFirst)
    }

    if let last = result.last, !".!?".contains(last) {
      result.append(".")
    }

    return result
  }

  private func buildMessages(systemPrompt: String?, messages: [ChatMessage])
    -> [OpenRouterChatRequest.Message]
  {
    var payload: [OpenRouterChatRequest.Message] = []
    if let systemPrompt {
      payload.append(.init(role: "system", content: systemPrompt))
    }
    payload += messages.map { message in
      .init(role: message.role.rawValue, content: message.content)
    }
    return payload
  }

  private func string(from data: Data?) -> String? {
    guard let data else { return nil }
    if let text = String(data: data, encoding: .utf8) {
      return text
    }
    return String(data: data, encoding: .ascii)
  }

  private func normalizedHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
    var normalized: [String: String] = [:]
    for (key, value) in headers {
      guard let keyString = key as? String else { continue }
      if let valueString = value as? String {
        normalized[keyString] = valueString
      } else {
        normalized[keyString] = String(describing: value)
      }
    }
    return normalized
  }

  private func buildTranscriptionResult(
    response: OpenRouterTranscriptionResponse,
    audioURL: URL,
    model: String,
    payload: Data
  ) async throws -> TranscriptionResult {
    let asset = AVURLAsset(url: audioURL)
    let durationTime = try await asset.load(.duration)
    let duration = durationTime.seconds
    let segments =
      response.segments?.map { segment in
        TranscriptionSegment(
          startTime: segment.start,
          endTime: segment.end,
          text: segment.text
        )
      } ?? [TranscriptionSegment(startTime: 0, endTime: duration, text: response.text)]

    return TranscriptionResult(
      text: response.text,
      segments: segments,
      confidence: response.confidence,
      duration: duration,
      modelIdentifier: model,
      cost: nil,
      rawPayload: String(data: payload, encoding: .utf8),
      debugInfo: nil
    )
  }

  private func applyBrandHeaders(_ request: inout URLRequest) {
    request.setValue(titleHeaderValue, forHTTPHeaderField: "X-Title")
    request.setValue(refererHeaderValue, forHTTPHeaderField: "HTTP-Referer")
    request.setValue(refererHeaderValue, forHTTPHeaderField: "Referer")
  }

  private func allowsLocalFallback(for model: String) -> Bool {
    if model.lowercased().hasPrefix("apple/") { return true }
    if model.lowercased().hasPrefix("local/") { return true }
    if model.lowercased() == "on-device" { return true }
    return false
  }

  /// Pre-warms the TCP/TLS connection to OpenRouter by making a lightweight HEAD request.
  /// This establishes and caches the connection for subsequent API calls.
  /// Failures are logged but do not throw - warming is best-effort.
  func warmUp() async {
    let startTime = CFAbsoluteTimeGetCurrent()
    let url = baseURL.appendingPathComponent("models")
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    applyBrandHeaders(&request)

    do {
      let (_, response) = try await session.data(for: request)
      let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
      if let http = response as? HTTPURLResponse {
        logger.info("Connection warm-up completed in \(elapsed, format: .fixed(precision: 1))ms (status: \(http.statusCode))")
      } else {
        logger.info("Connection warm-up completed in \(elapsed, format: .fixed(precision: 1))ms")
      }
    } catch {
      let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
      logger.warning("Connection warm-up failed after \(elapsed, format: .fixed(precision: 1))ms: \(error.localizedDescription, privacy: .public)")
    }
  }
}

private struct OpenRouterChatRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  let model: String
  let temperature: Double
  let messages: [Message]
}

private struct OpenRouterChatResponse: Decodable {
  struct Choice: Decodable {
    struct ChoiceMessage: Decodable {
      let role: String
      let content: String
    }

    let index: Int
    let finish_reason: String?
    let message: ChoiceMessage?
  }

  struct Usage: Decodable {
    let prompt_tokens: Int
    let completion_tokens: Int
  }

  let choices: [Choice]
  let usage: Usage?
}

private struct OpenRouterTranscriptionResponse: Decodable {
  struct Segment: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  let text: String
  let segments: [Segment]?
  let confidence: Double?
}

private struct OpenRouterValidationResponse: Decodable {
  struct ValidationData: Decodable {
    let valid: Bool?
  }

  let valid: Bool?
  let data: ValidationData?
}

private struct OpenRouterStreamingChatRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  let model: String
  let temperature: Double
  let messages: [Message]
  let stream: Bool
}

private struct OpenRouterStreamChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      let role: String?
      let content: String?
    }
    let delta: Delta?
    let finish_reason: String?
  }
  let choices: [Choice]
}

// @Implement: This class is responsible for interacting with the OpenRouter API and implements the LLMProtocols to do so. It takes the api key from SecureAppStorage
