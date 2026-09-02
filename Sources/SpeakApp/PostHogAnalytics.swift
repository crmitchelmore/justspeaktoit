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
    let createdAt: Date
    let event: String
    let distinctID: String
    let properties: [String: AnalyticsPropertyValue]
  }

  private let configuration: Configuration?
  private let queueURL: URL
  private let session: URLSession
  private var queue: [QueuedEvent] = []
  private var isOpen = false

  nonisolated static var isConfigured: Bool { Configuration.resolve() != nil }

  init(
    queueURL: URL,
    session: URLSession = .shared,
    configuration: (projectKey: String, endpoint: URL)? = nil
  ) {
    self.queueURL = queueURL
    self.session = session
    self.configuration = configuration.map {
      Configuration(projectKey: $0.projectKey, endpoint: $0.endpoint)
    }
      ?? Configuration.resolve()
    queue = Self.pruned(Self.loadQueue(from: queueURL))
  }

  func reopen() async throws {
    isOpen = true
    try await flush()
  }

  func capture(_ payload: ProductAnalyticsPayload) async throws {
    guard isOpen, configuration != nil else { return }
    queue.append(QueuedEvent(
      createdAt: Date(),
      event: payload.event,
      distinctID: payload.distinctID?.uuidString ?? "anonymous-counter",
      properties: payload.properties
    ))
    pruneQueue()
    try persistQueue()
    try await flush()
  }

  func purge() async throws {
    isOpen = false
    queue.removeAll(keepingCapacity: false)
    if FileManager.default.fileExists(atPath: queueURL.path) {
      try FileManager.default.removeItem(at: queueURL)
    }
  }

  func close() async { isOpen = false }

  private func flush() async throws {
    guard isOpen, let configuration else { return }
    while let next = queue.first {
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
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      queue.removeFirst()
      try persistQueue()
    }
  }

  private func pruneQueue(now: Date = Date()) {
    queue = Self.pruned(queue, now: now)
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
