import XCTest

@testable import SpeakApp

final class HistoryIssueReporterTests: XCTestCase {
  func testIssueURL_targetsGitHubIssueCreationWithBugLabel() throws {
    let item = makeErrorItem()
    let url = try XCTUnwrap(HistoryIssueReporter.issueURL(for: item))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
      item.value.map { (item.name, $0) }
    })

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "github.com")
    XCTAssertEqual(components.path, "/crmitchelmore/justspeaktoit/issues/new")
    XCTAssertEqual(query["labels"], "bug")
    XCTAssertTrue(query["title"]?.contains("[Bug]") == true)
    XCTAssertTrue(url.absoluteString.count <= HistoryIssueReporter.maximumURLLength)
  }

  func testIssueBody_includesDiagnosticsAndOmitsPrivatePayloads() {
    let item = makeErrorItem()
    let body = HistoryIssueReporter.issueBody(for: item)

    XCTAssertTrue(body.contains(item.id.uuidString))
    XCTAssertTrue(body.contains("The selected microphone is unavailable"))
    XCTAssertTrue(body.contains("MacBook Pro Microphone"))
    XCTAssertTrue(body.contains("Deepgram Nova-3"))
    XCTAssertTrue(body.contains("HTTP 500"))

    XCTAssertFalse(body.contains("secret dictated transcript"))
    XCTAssertFalse(body.contains("corrected private transcript"))
    XCTAssertFalse(body.contains("payload with private transcript"))
    XCTAssertFalse(body.contains("/Users/cm"))
    XCTAssertFalse(body.contains("real-token-value"))
  }

  private func makeErrorItem() -> HistoryItem {
    let date = Date(timeIntervalSince1970: 1_717_171_717)
    let diagnostic = HistoryDiagnosticContext(
      capturedAt: date,
      appVersion: "2.1.3",
      appBuild: "202606030123",
      operatingSystem: "Version 15.5 (Build 24F74)",
      processIdentifier: 1234,
      microphonePermission: "granted",
      inputDeviceName: "MacBook Pro Microphone",
      providerLabel: "Deepgram Nova-3",
      latencyTier: "Fast",
      transcriptionMode: "Remote Streaming",
      transcriptionModel: "deepgram/nova-3-streaming",
      postProcessingModel: "inception/mercury",
      speedMode: "Instant"
    )

    return HistoryItem(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      createdAt: date,
      updatedAt: date,
      modelsUsed: ["deepgram/nova-3-streaming"],
      modelUsages: [ModelUsage(modelIdentifier: "deepgram/nova-3-streaming", phase: .transcriptionLive)],
      rawTranscription: "secret dictated transcript",
      postProcessedTranscription: "corrected private transcript",
      recordingDuration: 3.4,
      cost: nil,
      audioFileURL: URL(fileURLWithPath: "/Users/cm/Library/Application Support/SpeakApp/Recordings/private.m4a"),
      networkExchanges: [
        HistoryNetworkExchange(
          url: URL(string: "wss://api.deepgram.com/v1/listen")!,
          method: "WebSocket",
          requestHeaders: ["Authorization": "Bearer real-token-value", "Model": "nova-3"],
          requestBodyPreview: "payload with private transcript",
          responseCode: 500,
          responseHeaders: ["Request-ID": "abc123"],
          responseBodyPreview: "payload with private transcript"
        )
      ],
      events: [
        HistoryEvent(kind: .recordingStarted, timestamp: date, description: "Recording started"),
        HistoryEvent(kind: .error, timestamp: date, description: "Diagnostic snapshot captured for issue report")
      ],
      phaseTimestamps: PhaseTimestamps(
        recordingStarted: date,
        recordingEnded: date.addingTimeInterval(3.4),
        transcriptionStarted: date.addingTimeInterval(3.5),
        transcriptionEnded: nil,
        postProcessingStarted: nil,
        postProcessingEnded: nil,
        outputDelivered: nil
      ),
      trigger: HistoryTrigger(
        gesture: .doubleTap,
        hotKeyDescription: "Fn",
        outputMethod: .none,
        destinationApplication: "Private Notes"
      ),
      personalCorrections: nil,
      errors: [
        HistoryError(
          phase: .recording,
          message: "The selected microphone is unavailable",
          debugDescription: "com.apple.coreaudio.avfaudio error 560227702 at /Users/cm/private"
        )
      ],
      diagnosticContext: diagnostic
    )
  }
}
