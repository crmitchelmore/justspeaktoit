#if !APP_STORE
import Foundation
import SpeakCore

/// The deliberately small PostHog transport used by direct/Sparkle builds.
///
/// The official SDK currently performs an unavoidable remote-config request and
/// bundles features this app has explicitly ruled out (autocapture, replay,
/// surveys and error capture). Posting the audited typed payload directly to the
/// EU `/capture/` endpoint keeps the network surface to one documented request.
actor PostHogProductAnalyticsSink: ProductAnalyticsSink {
  private struct Configuration: Sendable {
    let projectKey: String
    let endpoint: URL

    static func resolve(
      bundle: Bundle = .main,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Configuration? {
      let key = environment["POSTHOG_PROJECT_KEY"]
        ?? bundle.object(forInfoDictionaryKey: "PostHogProjectKey") as? String
      let host = environment["POSTHOG_HOST"]
        ?? bundle.object(forInfoDictionaryKey: "PostHogHost") as? String
        ?? "https://eu.i.posthog.com"
      guard let key, !key.isEmpty, let baseURL = URL(string: host) else { return nil }
      return Configuration(projectKey: key, endpoint: baseURL.appendingPathComponent("capture"))
    }
  }

  private struct QueuedEvent: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let event: String
    let distinctID: String
    let properties: [String: AnalyticsPropertyValue]

    init(createdAt: Date, payload: ProductAnalyticsPayload) {
      id = UUID()
      self.createdAt = createdAt
      event = payload.event
      distinctID = payload.distinctID?.uuidString ?? "anonymous-counter"
      properties = payload.properties
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // Queues written before request serialization did not carry an entry ID.
      id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
      createdAt = try container.decode(Date.self, forKey: .createdAt)
      event = try container.decode(String.self, forKey: .event)
      distinctID = try container.decode(String.self, forKey: .distinctID)
      properties = try container.decode([String: AnalyticsPropertyValue].self, forKey: .properties)
    }
  }

  private let configuration: Configuration?
  private let queueURL: URL
  private let session: URLSession
  private let now: @Sendable () -> Date
  private var queue: [QueuedEvent] = []
  private var isOpen = false
  private var activeFlushID: UUID?
  private var activeRequest: Task<(Data, URLResponse), Error>?

  nonisolated static var isConfigured: Bool { Configuration.resolve() != nil }

  init(
    queueURL: URL,
    session: URLSession = .shared,
    configuration: (projectKey: String, endpoint: URL)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.queueURL = queueURL
    self.session = session
    self.now = now
    self.configuration = configuration.map {
      Configuration(projectKey: $0.projectKey, endpoint: $0.endpoint)
    }
      ?? Configuration.resolve()
    queue = Self.pruned(Self.loadQueue(from: queueURL), now: now())
  }

  func reopen() async throws {
    pruneQueue()
    try persistQueue()
    isOpen = true
    try await flush()
  }

  func capture(_ payload: ProductAnalyticsPayload) async throws {
    guard isOpen, configuration != nil else { return }
    queue.append(QueuedEvent(createdAt: now(), payload: payload))
    pruneQueue()
    try persistQueue()
    try await flush()
  }

  func purge() async throws {
    stopRequests()
    queue.removeAll(keepingCapacity: false)
    if FileManager.default.fileExists(atPath: queueURL.path) {
      try FileManager.default.removeItem(at: queueURL)
    }
  }

  func close() async { stopRequests() }

  private func stopRequests() {
    isOpen = false
    activeFlushID = nil
    activeRequest?.cancel()
    activeRequest = nil
  }

  private func flush() async throws {
    guard isOpen, let configuration, activeFlushID == nil else { return }
    let flushID = UUID()
    activeFlushID = flushID
    defer {
      if activeFlushID == flushID {
        activeFlushID = nil
        activeRequest = nil
      }
    }
    while isOpen, activeFlushID == flushID {
      pruneQueue()
      try persistQueue()
      guard let next = queue.first else { return }
      var properties = next.properties.mapValues(\.foundationValue)
      properties["distinct_id"] = next.distinctID
      properties["$lib"] = "just-speak-to-it"
      properties["$lib_version"] = "1"
      properties["timestamp"] = ISO8601DateFormatter().string(from: next.createdAt)
      let body: [String: Any] = [
        "api_key": configuration.projectKey,
        "event": next.event,
        "properties": properties
      ]
      var request = URLRequest(url: configuration.endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      let requestTask = Task { [session, request] in
        try Task.checkCancellation()
        return try await session.data(for: request)
      }
      activeRequest = requestTask
      let (_, response) = try await requestTask.value
      // An opt-out can purge the queue and a later opt-in can start a new flush
      // while the cancelled request is finishing. Its response owns neither queue.
      guard isOpen, activeFlushID == flushID else { return }
      activeRequest = nil
      guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      // A concurrent capture may have evicted this entry at the queue cap.
      queue.removeAll { $0.id == next.id }
      try persistQueue()
    }
  }

  private func pruneQueue() {
    queue = Self.pruned(queue, now: now())
  }

  private func persistQueue() throws {
    if queue.isEmpty {
      if FileManager.default.fileExists(atPath: queueURL.path) {
        try FileManager.default.removeItem(at: queueURL)
      }
      return
    }
    try FileManager.default.createDirectory(
      at: queueURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(queue).write(
      to: queueURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }

  private static func loadQueue(from url: URL) -> [QueuedEvent] {
    guard let data = try? Data(contentsOf: url),
          let events = try? JSONDecoder().decode([QueuedEvent].self, from: data)
    else { return [] }
    return events
  }

  private static func pruned(_ events: [QueuedEvent], now: Date = Date()) -> [QueuedEvent] {
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    return Array(events.filter { $0.createdAt >= cutoff }.suffix(1_000))
  }
}
#endif
