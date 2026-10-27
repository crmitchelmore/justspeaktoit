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
    guard model.trimmingCharacters(in: .whitespacesAndNewlines) == CartesiaBatchClient.catalogID else {
      throw CartesiaLiveError.batchNotSupported
    }
    return try await CartesiaBatchClient(session: session).transcribeFile(
      at: url, apiKey: apiKey, language: language
    )
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
    request.setValue(CartesiaLiveClient.apiVersion, forHTTPHeaderField: "Cartesia-Version")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Non-HTTP response")
      }
      let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
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
    ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id)
      + ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
  }

  func createLiveTranscriber(
    apiKey: String,
    model: String = "ink-2",
    sampleRate: Int = 16_000
  ) -> CartesiaLiveTranscriber {
    CartesiaLiveTranscriber(apiKey: apiKey, model: model, sampleRate: sampleRate, session: session)
  }

  func createLiveTranscriber(
    apiKey: String, model: String, sampleRate: Int,
    postStopFinalizeBudget: TimeInterval, stopGracePeriod: TimeInterval
  ) -> CartesiaLiveTranscriber {
    CartesiaLiveTranscriber(client: CartesiaLiveClient(
      apiKey: apiKey, model: model, sampleRate: sampleRate, session: session,
      postStopFinalizeBudget: postStopFinalizeBudget, stopGracePeriod: stopGracePeriod
    ))
  }

}

/// One recording's capture adapter. Core owns the socket, bounded PCM queue,
/// close control, trailing-turn drain and rich terminal transcript snapshot.
final class CartesiaLiveTranscriber: @unchecked Sendable {
  static let apiVersion = CartesiaLiveClient.apiVersion
  static let preferredChunkBytes = 3_200
  static let minimumChunkBytes = 1_600

  struct Snapshot: Sendable {
    let transcript: StreamingTranscriptSnapshot
    let error: Error?
  }

  private let client: CartesiaLiveClient
  private let lock = NSLock()
  private enum State { case idle, started, retired }
  private var state = State.idle
  private var failure: Error?
  private var reportedFailure = false
  private var terminal: Snapshot?
  private var finishing: Task<Snapshot, Never>?
  private var finishCallers = 0

  convenience init(
    apiKey: String, model: String = "ink-2", sampleRate: Int = 16_000, session: URLSession = .shared
  ) {
    self.init(client: CartesiaLiveClient(apiKey: apiKey, model: model, sampleRate: sampleRate, session: session))
  }

  init(client: CartesiaLiveClient) { self.client = client }

  var finalisationBudget: TimeInterval { client.finalisationBudget ?? 0 }

  var snapshot: Snapshot {
    let transcript = client.transcriptSnapshot(captureDuration: 0)
    return lock.withLock { terminal ?? Snapshot(transcript: transcript, error: failure) }
  }

  /// Actual adapter callers awaiting the one owned finish (including joiners).
  var pendingFinishes: Int { lock.withLock { finishCallers } }

  func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
    let begin = lock.withLock { () -> Bool in
      guard state == .idle else { return false }
      state = .started
      return true
    }
    guard begin else { return }
    client.start(onTranscript: onTranscript, onError: { [weak self] error in
      guard let self else { return }
      self.lock.withLock { if self.failure == nil { self.failure = error } }
      onError(error)
    })
    // A concurrent stop may have preceded the synchronous Core start call.
    // Retire that owned connection too; this adapter cannot be restarted.
    if lock.withLock({ state == .retired }) { client.stop() }
  }

  func sendAudio(_ data: Data) {
    guard lock.withLock({ state != .retired }) else { return }
    client.sendAudio(data)
  }

  func finishAndWait() async -> Snapshot {
    if let terminal = lock.withLock({ terminal }) { return terminal }
    lock.withLock { finishCallers += 1 }
    defer { lock.withLock { finishCallers -= 1 } }
    return await withTaskCancellationHandler {
      let owned = lock.withLock { () -> Task<Snapshot, Never> in
        if let finishing { return finishing }
        // Unstructured ownership keeps a caller's cancellation from reaching
        // Core before this adapter records the shared cancellation outcome.
        let task = Task.detached(priority: Task.currentPriority) { [self] in
          _ = await client.finishAndWait()
          let transcript = client.transcriptSnapshot(captureDuration: 0)
          return lock.withLock {
            if let terminal { return terminal }
            let result = Snapshot(transcript: transcript, error: failure)
            terminal = result
            state = .retired
            return result
          }
        }
        finishing = task
        return task
      }
      return await owned.value
    } onCancel: { [weak self] in self?.stop() }
  }

  func takeFailureForReporting() -> Error? {
    lock.withLock {
      guard !reportedFailure, let failure else { return nil }
      reportedFailure = true
      return failure
    }
  }

  func stop() {
    lock.withLock {
      state = .retired
      // A late caller cannot retroactively change a published outcome.
      if terminal == nil, failure == nil { failure = CancellationError() }
    }
    client.stop()
  }

  nonisolated static func webSocketURL(model: String, sampleRate: Int) -> URL? {
    CartesiaLiveClient.webSocketURL(model: model, sampleRate: sampleRate)
  }

  nonisolated static func webSocketRequest(apiKey: String, model: String, sampleRate: Int) -> URLRequest? {
    CartesiaLiveClient.webSocketRequest(apiKey: apiKey, model: model, sampleRate: sampleRate)
  }
}
