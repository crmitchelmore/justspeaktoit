import Foundation

enum HistoryIssueReporter {
  static let repositoryIssueURL = URL(string: "https://github.com/crmitchelmore/justspeaktoit/issues/new")!
  static let maximumBodyLength = 6_000
  static let maximumURLLength = 7_500

  static func issueURL(for item: HistoryItem) -> URL? {
    var body = truncated(issueBody(for: item), limit: maximumBodyLength)
    var components = URLComponents(url: repositoryIssueURL, resolvingAgainstBaseURL: false)
    components?.queryItems = queryItems(for: item, body: body)

    while let url = components?.url,
      url.absoluteString.count > maximumURLLength,
      body.count > 1_500
    {
      body = truncated(body, limit: body.count - 750)
      components?.queryItems = queryItems(for: item, body: body)
    }

    return components?.url
  }

  static func issueTitle(for item: HistoryItem) -> String {
    let phase = item.errors.first?.phase.rawValue ?? "session"
    let message = item.errors.first?.message ?? "Session error"
    return "[Bug] \(phase.capitalized) error: \(truncated(publicSafe(message), limit: 72))"
  }

  static func issueBody(for item: HistoryItem) -> String {
    let diagnostics = item.diagnosticContext.map(diagnosticLines) ?? ["- Not captured"]
    let errorLines = item.errors.isEmpty
      ? ["- No structured errors recorded"]
      : item.errors.enumerated().map { index, error in
        let debug = error.debugDescription.map { "\n  - Debug: `\(publicSafe($0))`" } ?? ""
        return """
        \(index + 1). **\(error.phase.rawValue)** at \(iso8601(error.occurredAt))
          - Message: \(publicSafe(error.message))\(debug)
        """
      }
    let eventLines = item.events.isEmpty
      ? ["- No events recorded"]
      : item.events.map { event in
        "- \(iso8601(event.timestamp)) [\(event.kind.rawValue)] \(publicSafe(event.description))"
      }
    let networkLines = item.networkExchanges.isEmpty
      ? ["- No network exchanges recorded"]
      : item.networkExchanges.map { exchange in
        let requestHeaderKeys = exchange.requestHeaders.keys.sorted().joined(separator: ", ")
        let responseHeaderKeys = exchange.responseHeaders.keys.sorted().joined(separator: ", ")
        return """
        - \(exchange.method) \(publicSafe(exchange.url.host ?? exchange.url.absoluteString))\(exchange.url.path) -> HTTP \(exchange.responseCode)
          - Request headers: \(requestHeaderKeys.isEmpty ? "none" : requestHeaderKeys)
          - Response headers: \(responseHeaderKeys.isEmpty ? "none" : responseHeaderKeys)
          - Payload previews omitted from public issue prefill for privacy.
        """
      }

    let audioReference = item.audioFileURL?.lastPathComponent ?? "none"
    let models = item.modelUsages.isEmpty
      ? item.modelsUsed.sorted().joined(separator: ", ")
      : item.modelUsages.map { "\($0.phase.rawValue): \($0.modelIdentifier)" }.joined(separator: ", ")
    let recordingDuration = item.recordingDuration > 0
      ? String(format: "%.2fs", item.recordingDuration)
      : "unknown"

    return """
    ## Description
    An in-app error was recorded by JustSpeakToIt. Please describe what you were doing when this happened:

    ## History reference
    - History ID: `\(item.id.uuidString)`
    - Created: \(iso8601(item.createdAt))
    - Updated: \(iso8601(item.updatedAt))
    - Recording duration: \(recordingDuration)
    - Audio file: \(publicSafe(audioReference))
    - Models: \(models.isEmpty ? "none recorded" : publicSafe(models))

    ## Errors
    \(errorLines.joined(separator: "\n"))

    ## Diagnostic context
    \(diagnostics.joined(separator: "\n"))

    ## Event timeline
    \(eventLines.joined(separator: "\n"))

    ## Network metadata
    \(networkLines.joined(separator: "\n"))

    ## Privacy note
    This prefilled issue intentionally omits transcript text, API payload bodies, full local file paths, destination app names, and secrets because GitHub issues are public. Add any extra private context manually only if you are comfortable publishing it.
    """
  }

  private static func queryItems(for item: HistoryItem, body: String) -> [URLQueryItem] {
    [
      URLQueryItem(name: "title", value: issueTitle(for: item)),
      URLQueryItem(name: "body", value: body),
      URLQueryItem(name: "labels", value: "bug")
    ]
  }

  private static func diagnosticLines(_ context: HistoryDiagnosticContext) -> [String] {
    [
      "- Captured: \(iso8601(context.capturedAt))",
      "- App: \(context.appVersion) (\(context.appBuild))",
      "- macOS: \(publicSafe(context.operatingSystem))",
      "- Process ID: \(context.processIdentifier)",
      "- Microphone permission: \(context.microphonePermission)",
      "- Input device: \(publicSafe(context.inputDeviceName))",
      "- Provider: \(publicSafe(context.providerLabel))",
      "- Latency: \(context.latencyTier)",
      "- Transcription mode: \(context.transcriptionMode)",
      "- Transcription model: \(publicSafe(context.transcriptionModel))",
      "- Post-processing model: \(publicSafe(context.postProcessingModel))",
      "- Speed mode: \(context.speedMode)"
    ]
  }

  private static func truncated(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    let suffix = "\n\n[Report truncated to keep the GitHub issue URL within a safe length.]"
    let prefixLimit = max(0, limit - suffix.count)
    return String(value.prefix(prefixLimit)) + suffix
  }

  private static func publicSafe(_ value: String) -> String {
    var result = replacing(pattern: #"/Users/[^/\s]+"#, in: value, with: "/Users/<redacted>")
    result = replacing(pattern: #"(?i)(authorization|api[-_ ]?key|token|secret)\s*[:=]\s*\S+"#, in: result, with: "$1=<redacted>")
    return result
  }

  private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
