import AVFoundation
import Foundation
import SpeakCore

/// Routes cleanup and recorded-file transcription through the paid service when
/// the user is entitled, and otherwise delegates to the existing
/// bring-your-own-key client.
///
/// The delegation is the point: this wrapper sits in the composition root in
/// front of `OpenRouterAPIClient`, so a user who never subscribes gets byte-for-byte
/// the previous behaviour, and a subscriber whose server call fails transiently
/// silently drops back to their own configuration rather than losing dictation.
actor PaidAccessProxyClient: StreamingChatLLMClient, BatchTranscriptionClient {

  private let fallback: any StreamingChatLLMClient & BatchTranscriptionClient
  private let paidClient: any PaidAccessClienting
  private let sessionProvider: @Sendable () async -> PaidAccessSession?
  private let routerProvider: @Sendable () async -> PaidAccessRouter

  init(
    fallback: any StreamingChatLLMClient & BatchTranscriptionClient,
    paidClient: any PaidAccessClienting,
    sessionProvider: @escaping @Sendable () async -> PaidAccessSession?,
    routerProvider: @escaping @Sendable () async -> PaidAccessRouter
  ) {
    self.fallback = fallback
    self.paidClient = paidClient
    self.sessionProvider = sessionProvider
    self.routerProvider = routerProvider
  }

  // MARK: - Routing

  /// Resolves the route for an operation, returning `nil` whenever the request
  /// should go through the user's own client.
  private func paidRoute(
    for operation: PaidOperation,
    configuredModel: String
  ) async throws -> (route: PaidRoute, session: PaidAccessSession)? {
    let router = await self.routerProvider()
    let decision = try router.decide(for: operation, configuredModel: configuredModel)
    guard case .paidService(let route) = decision else { return nil }
    guard let session = await self.sessionProvider() else { return nil }
    return (route, session)
  }

  // MARK: - Chat

  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    guard
      let resolved = try await self.paidRoute(for: .postProcessing, configuredModel: model)
    else {
      return try await self.fallback.sendChat(
        systemPrompt: systemPrompt,
        messages: messages,
        model: model,
        temperature: temperature
      )
    }

    do {
      let text = try await self.paidClient.postProcess(
        session: resolved.session,
        text: Self.userText(from: messages),
        systemPrompt: systemPrompt,
        temperature: temperature,
        idempotencyKey: PaidAccessHTTPClient.newIdempotencyKey()
      )
      return ChatResponse(
        messages: [ChatMessage(role: .assistant, content: text)],
        finishReason: "stop",
        // Cost accounting lives in the server's usage ledger; the client is
        // never told what a request cost and never reports one.
        cost: nil,
        rawPayload: nil
      )
    } catch let error as PaidAccessError where error.permitsSilentFallback {
      return try await self.fallback.sendChat(
        systemPrompt: systemPrompt,
        messages: messages,
        model: model,
        temperature: temperature
      )
    }
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
          let resolved = try await self.paidRoute(
            for: .postProcessing,
            configuredModel: model
          )
          guard resolved != nil else {
            // Not entitled: hand the caller the real streaming client so live
            // typing behaviour is unchanged.
            for try await chunk in self.fallbackStream(
              systemPrompt: systemPrompt,
              messages: messages,
              model: model,
              temperature: temperature
            ) {
              continuation.yield(chunk)
            }
            continuation.finish()
            return
          }

          // The paid endpoint returns a completed transcript rather than a
          // token stream, so the whole result is emitted once.
          let response = try await self.sendChat(
            systemPrompt: systemPrompt,
            messages: messages,
            model: model,
            temperature: temperature
          )
          if let text = response.messages.last?.content {
            continuation.yield(text)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  private nonisolated func fallbackStream(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let stream = await self.fallback.sendChatStreaming(
            systemPrompt: systemPrompt,
            messages: messages,
            model: model,
            temperature: temperature
          )
          for try await chunk in stream {
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  // MARK: - Batch transcription

  func transcribeFile(
    at url: URL,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    guard
      let contentType = Self.contentType(for: url),
      let resolved = try await self.paidRoute(
        for: .batchTranscription,
        configuredModel: model
      )
    else {
      return try await self.fallback.transcribeFile(at: url, model: model, language: language)
    }

    do {
      let audio = try Data(contentsOf: url)
      let text = try await self.paidClient.transcribe(
        session: resolved.session,
        audio: audio,
        contentType: contentType,
        language: language,
        idempotencyKey: PaidAccessHTTPClient.newIdempotencyKey()
      )
      let duration = await Self.audioDuration(of: url)
      return TranscriptionResult(
        text: text,
        segments: [TranscriptionSegment(startTime: 0, endTime: duration, text: text)],
        confidence: nil,
        duration: duration,
        modelIdentifier: resolved.route.model,
        cost: nil,
        rawPayload: nil,
        debugInfo: nil
      )
    } catch let error as PaidAccessError where error.permitsSilentFallback {
      return try await self.fallback.transcribeFile(at: url, model: model, language: language)
    }
  }

  // MARK: - Helpers

  private static func audioDuration(of url: URL) async -> TimeInterval {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return 0 }
    return duration.seconds.isFinite ? duration.seconds : 0
  }

  /// The paid cleanup endpoint takes a single transcript, so only the most
  /// recent user turn is sent. Nothing else in the conversation is uploaded.
  private static func userText(from messages: [ChatMessage]) -> String {
    messages.last(where: { $0.role == .user })?.content
      ?? messages.last?.content
      ?? ""
  }

  /// Returns `nil` for formats the paid endpoint does not accept, which sends
  /// the request down the user's own client instead of failing it.
  private static func contentType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "wav": return "audio/wav"
    case "m4a", "mp4": return "audio/mp4"
    case "mp3": return "audio/mpeg"
    default: return nil
    }
  }
}
