#if !APP_STORE
import Foundation

struct AnalyticsInspectionRecord: Identifiable, Sendable {
  enum Status: String, Codable, Sendable {
    case queued = "Queued locally"
    case sending = "Sending"
    case httpAcknowledged = "HTTP acknowledged"
    case retryPending = "Retry pending"
    case rejected = "Not acknowledged"
    case persistenceFailed = "Local persistence failed"
  }

  let id: UUID
  let createdAt: Date
  let event: String
  let status: Status
  /// The serialized event and properties, without the ingestion credential.
  let envelope: Data
  var json: String { String(data: envelope, encoding: .utf8) ?? "" }
}

struct AnalyticsInspectionSnapshot: Sendable {
  let endpoint: String
  let configured: Bool
  let isOpen: Bool
  let isDisabled: Bool
  let queueDepth: Int
  let records: [AnalyticsInspectionRecord]

  static func sanitizedEndpoint(_ url: URL?) -> String {
    guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "Not configured"
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? "Not configured"
  }

  func exportData() throws -> Data {
    let records: [[String: Any]] = try self.records.map {
      ["id": $0.id.uuidString, "created_at": ISO8601DateFormatter().string(from: $0.createdAt),
       "status": $0.status.rawValue, "envelope": try JSONSerialization.jsonObject(with: $0.envelope)]
    }
    return try JSONSerialization.data(withJSONObject: [
      "endpoint": endpoint, "queue_depth": queueDepth, "records": records,
      "scope": "At most 100 events from this launch; valid queued events survive relaunch.",
      "authentication": "Ingestion credential omitted"
    ], options: [.prettyPrinted, .sortedKeys])
  }
}
#endif
