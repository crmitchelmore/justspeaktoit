import Foundation
import os.log

/// Manages fast-lane "tail rewrite" for live polish during transcription.
/// Debounces requests, cancels in-flight requests when new text arrives, and applies patches.
@MainActor
final class LivePolishManager: ObservableObject {
  /// The polished tail text (updates frequently during live transcription)
  @Published private(set) var polishedTail: String = ""

  /// Whether a polish request is currently in flight
  @Published private(set) var isPolishing: Bool = false

  private let client: ChatLLMClient
  private let settings: AppSettings
  private let log = Logger(subsystem: "com.github.speakapp", category: "LivePolish")

  /// Debounce interval in seconds
  private var debounceInterval: TimeInterval = 0.5

  /// Minimum characters of new content before triggering polish
  private var minDeltaChars: Int = 20

  /// Task for the current debounce timer
  private var debounceTask: Task<Void, Never>?

  /// Task for the current in-flight LLM request
  private var polishTask: Task<Void, Never>?

  /// Last text that was sent for polishing
  private var lastPolishedInput: String = ""

  /// Callback when polish completes
  var onPolishComplete: ((String) -> Void)?

  static let polishPrompt = """
    You are a real-time transcription cleaner. You receive raw speech-to-text output.

    YOUR TASK: Fix only obvious errors in spelling, punctuation, and capitalization.

    RULES:
    - Output ONLY the cleaned text, nothing else
    - Preserve meaning exactly
    - Keep it fast - minimal changes only
    - Do not add or remove words
    - Do not add commentary
    """

  init(client: ChatLLMClient, settings: AppSettings) {
    self.client = client
    self.settings = settings
  }

  /// Configure debounce and delta thresholds
  func configure(debounceInterval: TimeInterval = 0.5, minDeltaChars: Int = 20) {
    self.debounceInterval = debounceInterval
    self.minDeltaChars = minDeltaChars
  }

  /// Called when new transcript text is available. Debounces and triggers polish.
  func textDidChange(stableContext: String, tailText: String) {
    // Cancel existing debounce
    debounceTask?.cancel()

    // Check if we have enough new content
    let combinedInput = tailText
    let delta = combinedInput.count - lastPolishedInput.count
    guard delta >= minDeltaChars || lastPolishedInput.isEmpty else {
      return
    }

    // Start debounce timer
    debounceTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(self?.debounceInterval ?? 0.5) * 1_000_000_000)
        await self?.triggerPolish(stableContext: stableContext, tailText: tailText)
      } catch {
        // Cancelled - ignore
      }
    }
  }

  /// Force immediate polish (e.g., on utterance boundary)
  func polishNow(stableContext: String, tailText: String) async {
    debounceTask?.cancel()
    await triggerPolish(stableContext: stableContext, tailText: tailText)
  }

  /// Cancel any pending or in-flight polish requests
  func cancel() {
    debounceTask?.cancel()
    debounceTask = nil
    polishTask?.cancel()
    polishTask = nil
    isPolishing = false
  }

  /// Reset state for a new session
  func reset() {
    cancel()
    polishedTail = ""
    lastPolishedInput = ""
  }

  private func triggerPolish(stableContext: String, tailText: String) async {
    guard !tailText.isEmpty else { return }

    // Cancel any existing in-flight request (latest-wins)
    polishTask?.cancel()

    isPolishing = true
    lastPolishedInput = tailText

    polishTask = Task { [weak self] in
      guard let self else { return }

      do {
        let polished = try await performPolish(stableContext: stableContext, tailText: tailText)

        // Check if we were cancelled
        try Task.checkCancellation()

        await MainActor.run {
          self.polishedTail = polished
          self.isPolishing = false
          self.onPolishComplete?(polished)
        }
      } catch is CancellationError {
        // Expected - newer request superseded this one
        await MainActor.run {
          self.isPolishing = false
        }
      } catch {
        self.log.error("Polish failed: \(error.localizedDescription, privacy: .public)")
        await MainActor.run {
          self.isPolishing = false
        }
      }
    }
  }

  private func performPolish(stableContext: String, tailText: String) async throws -> String {
    // Build minimal prompt with context
    var userMessage = ""
    if !stableContext.isEmpty {
      userMessage = "[Context: ...\(stableContext)]\n\nClean this text:\n\(tailText)"
    } else {
      userMessage = "Clean this text:\n\(tailText)"
    }

    // Use fast model for polish
    let model = resolveModel()

    let response = try await client.sendChat(
      systemPrompt: Self.polishPrompt,
      messages: [ChatMessage(role: .user, content: userMessage)],
      model: model,
      temperature: 0.0
    )

    let result = response.messages.last(where: { $0.role == .assistant })?.content ?? tailText
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resolveModel() -> String {
    // Use fast polish model if set, otherwise fall back to post-processing model
    let configured = settings.livePolishModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty {
      return configured
    }

    let postProcessing = settings.postProcessingModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !postProcessing.isEmpty {
      return postProcessing
    }

    // Fast default
    return "openai/gpt-4.1-mini"
  }
}
