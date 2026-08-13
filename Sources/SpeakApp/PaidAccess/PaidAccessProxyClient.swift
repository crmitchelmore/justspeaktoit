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

  /// The bring-your-own-key client every non-paid request goes to.
  nonisolated let fallback: OpenRouterAPIClient
  private let paidClient: any PaidAccessClienting
  private let sessionProvider: @Sendable () async -> PaidAccessSession?
  private let routerProvider: @Sendable () async -> PaidAccessRouter

  init(
    fallback: OpenRouterAPIClient,
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

  /// Whether a paid route would currently be used for transcript cleanup of the
  /// given model.
  ///
  /// Callers use this to decide whether a personal API key is still required,
  /// so it must be asked about the model the request will actually use.
  func isPaidRoutingActive(configuredModel: String) async -> Bool {
    let router = await self.routerProvider()
    guard
      let decision = try? router.decide(
        for: .postProcessing,
        configuredModel: configuredModel
      ),
      decision.usesPaidService
    else {
      return false
    }
    return await self.sessionProvider() != nil
  }

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

  /// Whether a paid-path failure should be completed through the user's own
  /// client rather than failed.
  ///
  /// Wider than ``PaidAccessError/permitsSilentFallback`` by exactly one case:
  /// `unsupportedOperation` is still an error worth surfacing in Settings — the
  /// server publishes no paid route for that operation — but it must not cost
  /// the user a recording they have already made. Failing a request is never
  /// the right answer when the user's own key or an on-device model can finish
  /// it.
  private static func completesThroughFallback(_ error: PaidAccessError) -> Bool {
    if case .unsupportedOperation = error { return true }
    return error.permitsSilentFallback
  }

  // MARK: - Chat

  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    // Resolving the route is inside the `do`: a routing failure must cost the
    // user the paid model, never the text they just dictated.
    do {
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

      let text = Self.userText(from: messages)
      let result = try await self.paidClient.postProcess(
        session: resolved.session,
        text: text,
        systemPrompt: systemPrompt,
        temperature: temperature,
        // Each call is its own attempt: nothing here retries, and a timeout
        // falls back to the user's own client rather than trying again. Reusing
        // a key across calls would refuse a second, deliberate cleanup of the
        // same text — which is ordinary use, not a duplicate.
        idempotencyKey: PaidAccessHTTPClient.idempotencyKey(
          operation: .postProcessing,
          attemptID: UUID().uuidString,
          parameters: [resolved.route.model, systemPrompt ?? "", String(temperature)],
          payload: Data(text.utf8)
        )
      )
      return ChatResponse(
        messages: [ChatMessage(role: .assistant, content: result)],
        finishReason: "stop",
        // Cost accounting lives in the server's usage ledger; the client is
        // never told what a request cost and never reports one.
        cost: nil,
        rawPayload: nil
      )
    } catch let error as PaidAccessError where Self.completesThroughFallback(error) {
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
      let task = Task {
        do {
          // A routing failure is treated exactly like "not entitled": the
          // stream still runs, through the user's own client. Throwing here
          // would end the stream and lose what the user dictated.
          let resolved: (route: PaidRoute, session: PaidAccessSession)?
          do {
            resolved = try await self.paidRoute(for: .postProcessing, configuredModel: model)
          } catch {
            resolved = nil
          }
          guard resolved != nil else {
            // Not entitled: stream straight from the user's own client so live
            // typing behaviour is byte-for-byte what it was before paid access.
            for try await chunk in self.fallback.sendChatStreaming(
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

      // Without this, cancelling cleanup would leave the upstream request
      // running — a regression for subscribers and non-subscribers alike.
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Batch transcription

  func transcribeFile(
    at url: URL,
    model: String,
    language: String?
  ) async throws -> TranscriptionResult {
    // As above: resolving the route sits inside the `do` so that a routing
    // failure falls back to the user's own client instead of throwing away a
    // recording that has already been made.
    do {
      guard
        let resolved = try await self.paidRoute(
          for: .batchTranscription,
          configuredModel: model
        )
      else {
        return try await self.fallback.transcribeFile(at: url, model: model, language: language)
      }

      // The app records AAC in an `.m4a` but the endpoint takes WAV only, so the
      // recording is converted here. A file that cannot be converted falls back
      // to the user's own client rather than failing the dictation.
      let contentType = PaidAudioPayload.contentType
      let audio: Data
      do {
        audio = try PaidAudioPayload.wavData(contentsOf: url)
      } catch {
        return try await self.fallback.transcribeFile(at: url, model: model, language: language)
      }

      let text = try await self.paidClient.transcribe(
        session: resolved.session,
        audio: audio,
        contentType: contentType,
        language: language,
        // A recording is a natural attempt identity: transcribing the same file
        // again is a retry, recording the same words afresh is a new request.
        idempotencyKey: PaidAccessHTTPClient.idempotencyKey(
          operation: .batchTranscription,
          attemptID: Self.attemptID(for: url),
          parameters: [resolved.route.model, contentType, language ?? ""],
          payload: audio
        )
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
    } catch let error as PaidAccessError where Self.completesThroughFallback(error) {
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

  // Format selection lives in `PaidAudioPayload`: the endpoint takes WAV only,
  // and anything else is converted rather than refused.

  /// The attempt identity for transcribing a recording.
  ///
  /// Recordings are written as `Recording-<UUID>.m4a`, so the file's own name is
  /// stable for exactly as long as the request is worth retrying and differs for
  /// the next recording — even one of identical words. The audio itself is
  /// hashed alongside this, so two imported files that happen to share a name
  /// still get different keys.
  private static func attemptID(for url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    return name.isEmpty ? UUID().uuidString : name
  }
}
