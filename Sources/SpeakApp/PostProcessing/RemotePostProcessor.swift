import SpeakCore
import Foundation
import os.log

/// Sends a cleanup prompt to the configured chat client: streaming first when
/// enabled and supported, then a single non-streaming request as the fallback.
///
/// Stateless by design: the settings are read through lazy accessors so each
/// request sees the values current at the moment it is made, without this type
/// constructing settings, secrets, local model managers or persistent state.
enum RemotePostProcessor {
  struct Delivery {
    let log: Logger
    let streamingUpdate: ((String) -> Void)?
    let diagnostic: ((RequestDiagnosticContext.PostProcessingObservation) -> Void)?
  }

  static func process(
    client: ChatLLMClient, rawText: String, promptPayload: PostProcessingPromptPayload,
    settings: (streamingEnabled: () -> Bool, temperature: () -> Double),
    delivery: Delivery
  ) async -> Result<PostProcessingOutcome, Error> {
    let request = Request(
      rawText: rawText, promptPayload: promptPayload, temperature: settings.temperature, delivery: delivery
    )
    var fallbackObserved: Bool?
    if settings.streamingEnabled(),
       let streamingClient = client as? StreamingChatLLMClient {
      do {
        return try await request.stream(with: streamingClient)
      } catch {
        delivery.log.warning(
          "Streaming failed, falling back to non-streaming: \(error.localizedDescription, privacy: .public)"
        )
        fallbackObserved = true
      }
    }
    return await request.sendOnce(with: client, fallbackObserved: fallbackObserved)
  }

  /// One cleanup request; the streaming attempt and the fallback share it.
  private struct Request {
    let rawText: String
    let promptPayload: PostProcessingPromptPayload
    /// Read at each attempt so the fallback uses the temperature current then.
    let temperature: () -> Double
    let delivery: Delivery

    private var model: String { promptPayload.modelIdentifier }
    private var messages: [ChatMessage] { [ChatMessage(role: .user, content: promptPayload.userPrompt)] }

    func stream(with client: StreamingChatLLMClient) async throws -> Result<PostProcessingOutcome, Error> {
      var accumulated = ""
      let messages = messages
      let requestedTemperature = temperature()
      delivery.diagnostic?(RemotePostProcessor.observation(model: model, streaming: true))
      let stream = client.sendChatStreaming(
        systemPrompt: promptPayload.systemPrompt,
        messages: messages,
        model: model,
        temperature: requestedTemperature
      )

      for try await chunk in stream {
        accumulated += chunk
        delivery.streamingUpdate?(accumulated)
      }

      let cleaned = accumulated.isEmpty ? rawText : accumulated
      return .success(outcome(processed: cleaned, response: nil))
    }

    func sendOnce(with client: ChatLLMClient, fallbackObserved: Bool?) async -> Result<PostProcessingOutcome, Error> {
      do {
        let messages = messages
        let requestedTemperature = temperature()
        delivery.diagnostic?(RemotePostProcessor.observation(
          model: model, streaming: false, fallbackObserved: fallbackObserved
        ))
        let response = try await client.sendChat(
          systemPrompt: promptPayload.systemPrompt,
          messages: messages,
          model: model,
          temperature: requestedTemperature
        )

        let cleaned =
          response.messages.last(where: { $0.role == .assistant })?.content
          ?? rawText
        return .success(outcome(processed: cleaned, response: response))
      } catch {
        delivery.log.error("Post-processing failed: \(error.localizedDescription, privacy: .public)")
        delivery.diagnostic?(RemotePostProcessor.observation(
          model: model, streaming: false, fallbackObserved: fallbackObserved,
          failure: TranscriptionDiagnostics.failure(error, stage: .postProcessing)
        ))
        return .failure(error)
      }
    }

    private func outcome(processed: String, response: ChatResponse?) -> PostProcessingOutcome {
      .init(
        original: rawText,
        processed: processed,
        response: response,
        systemPrompt: promptPayload.systemPrompt,
        promptPayload: promptPayload
      )
    }
  }

  fileprivate static func observation(
    model: String, streaming: Bool, fallbackObserved: Bool? = nil,
    failure: RequestDiagnosticContext.Failure? = nil
  ) -> RequestDiagnosticContext.PostProcessingObservation {
    .init(handoff: .init(provenance: .observedHandoff, postProcessingModel: .project(model),
                         options: .init(streamingEnabled: streaming)),
          finalFailure: failure, fallbackObserved: fallbackObserved)
  }
}
