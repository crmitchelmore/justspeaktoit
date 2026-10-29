import SpeakCore
import XCTest

@testable import SpeakApp

final class HistoryIssueReporterTests: XCTestCase {
  func testIssueURL_targetsGitHubWithExactReviewedDraft() throws {
    let item = makeErrorItem()
    let report = HistoryIssueReporter.report(for: item)
    let url = try XCTUnwrap(HistoryIssueReporter.issueURL(for: item))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
      item.value.map { (item.name, $0) }
    })

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "github.com")
    XCTAssertEqual(components.path, "/crmitchelmore/justspeaktoit/issues/new")
    XCTAssertEqual(query["labels"], "bug")
    XCTAssertEqual(query["title"], report.title)
    XCTAssertEqual(query["body"], report.body)
    XCTAssertEqual(HistoryIssueReporter.issueTitle(for: item), report.title)
    XCTAssertEqual(HistoryIssueReporter.issueBody(for: item), report.body)
  }

  func testLegacyHistory_doesNotExportPrivateFieldsOrInventEffectiveSettings() throws {
    let item = makeErrorItem()
    let report = HistoryIssueReporter.report(for: item)
    let publicOutputs = report.title + report.body + report.jsonString
      + (report.issueURL?.absoluteString ?? "") + IssueDiagnosticReport.attachmentFilename
    for excluded in [
      item.id.uuidString, "1717171717", "202606030123", "2.1.3", "24F74", "1234",
      "The selected microphone is unavailable", "MacBook Pro Microphone", "Deepgram Nova-3",
      "deepgram/nova-3-streaming", "inception/mercury", "secret dictated transcript",
      "corrected private transcript", "private.m4a", "/Users/cm", "api.deepgram.com",
      "WebSocket", "Authorization", "real-token-value", "Request-ID", "abc123",
      "payload with private transcript", "Recording started", "Diagnostic snapshot captured",
      "Private Notes", "com.apple.coreaudio.avfaudio", "560227702"
    ] {
      XCTAssertFalse(publicOutputs.contains(excluded), "Excluded legacy data appeared in report")
    }
    XCTAssertEqual(report.jsonData, Data(report.jsonString.utf8))
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    XCTAssertEqual(payload["contextState"] as? String, "missingLegacyContext")
    XCTAssertNil(payload["context"])
    let failures = try XCTUnwrap(payload["failures"] as? [[String: Any]])
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(failures.first?["domain"] as? String, "unknown")
    XCTAssertEqual(failures.first?["code"] as? String, "unknown")
    // No recorded field can establish the historical request's effective configuration.
    XCTAssertEqual(report.jsonData, HistoryIssueReporter.report(for: makeErrorItem()).jsonData)
  }

  func testRemovingDiagnosticsEmitsExplicitOmissionsWithoutHistoricalDetails() throws {
    let report = HistoryIssueReporter.report(for: makeErrorItem(), includeDiagnostics: false)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    XCTAssertNil(payload["failures"])
    XCTAssertNil(payload["environment"])
    XCTAssertNil(payload["recordedModels"])
    XCTAssertNil(payload["timeline"])
    XCTAssertNil(payload["context"])
    XCTAssertEqual(payload["omissionReason"] as? String, "userRemoved")
    XCTAssertEqual(Set(payload["omittedSections"] as? [String] ?? []),
                   Set(IssueDiagnosticReport.Section.allCases.map(\.rawValue)))
    XCTAssertEqual(payload["contextState"] as? String, "userRemoved")
    XCTAssertEqual(Data(report.jsonString.utf8), report.jsonData)
  }

  func testRawErrorChanges_doNotChangeGeneratedReport() {
    let ordinary = HistoryIssueReporter.report(for: makeErrorItem())
    let hostile = HistoryIssueReporter.report(for: makeErrorItem(
      errorMessage: String(repeating: "PRIVATE_ERROR_/Users/secret/token=canary ", count: 1_000)
    ))
    XCTAssertEqual(ordinary.title, hostile.title)
    XCTAssertEqual(ordinary.body, hostile.body)
    XCTAssertEqual(ordinary.jsonData, hostile.jsonData)
    XCTAssertEqual(ordinary.issueURL, hostile.issueURL)
  }

  func testRecordedAdmissionUsesOnlyItsSafeContextAlongsideLegacyPrivateFields() throws {
    let model = try XCTUnwrap(ModelCatalog.allOptions.first)
    let context = RequestDiagnosticContext(
      model: .project(model.id), postProcessingModel: .project("PRIVATE_CUSTOM_MODEL_CANARY"), mode: .batch,
      options: .init(postProcessingEnabled: true, streamingEnabled: false)
    )
    let report = HistoryIssueReporter.report(for: makeErrorItem(requestContext: context))
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    XCTAssertEqual(payload["contextState"] as? String, "admission")
    let recorded = try XCTUnwrap(payload["context"] as? [String: Any])
    XCTAssertEqual((recorded["model"] as? [String: Any])?["identifier"] as? String, model.id)
    XCTAssertNil(recorded["observedProvider"])
    XCTAssertEqual(recorded["mode"] as? String, "batch")
    XCTAssertEqual((recorded["options"] as? [String: Any])?["postProcessingEnabled"] as? Bool, true)
    let outputs = report.title + report.body + report.jsonString + (report.issueURL?.absoluteString ?? "")
    for excluded in ["PRIVATE_CUSTOM_MODEL_CANARY", "secret dictated transcript", "private.m4a", "real-token-value"] {
      XCTAssertFalse(outputs.contains(excluded))
    }
  }

  func testRemovingRecordedAdmissionRemovesItsContextFromEveryActionPayload() throws {
    let model = try XCTUnwrap(ModelCatalog.allOptions.first)
    let item = makeErrorItem(requestContext: .init(model: .project(model.id), mode: .batch))
    let report = HistoryIssueReporter.report(for: item, includeDiagnostics: false)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    XCTAssertNil(payload["context"])
    XCTAssertEqual(payload["contextState"] as? String, "userRemoved")
    XCTAssertFalse(report.body.contains(model.id))
    XCTAssertFalse(report.issueURL?.absoluteString.contains(model.id) ?? false)
  }

  // swiftlint:disable:next function_body_length
  private func makeErrorItem(
    errorMessage: String = "The selected microphone is unavailable", requestContext: RequestDiagnosticContext? = nil
  ) -> HistoryItem {
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
      speedMode: "Instant", requestContext: requestContext
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
          message: errorMessage,
          debugDescription: """
          com.apple.coreaudio.avfaudio error 560227702 with Authorization: Bearer real-token-value at /Users/cm/private
          """
        )
      ],
      diagnosticContext: diagnostic
    )
  }
}
