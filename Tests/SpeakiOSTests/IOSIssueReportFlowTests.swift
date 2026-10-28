#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSIssueReportFlowTests: XCTestCase {
    func testLegacyRowCanariesNeverEnterAnyReportSurface() throws {
        let values = ["CANARY-transcript", "CANARY-polished", "custom/CANARY-model", "CANARY-platform",
                      "CANARY-secret-error-/Users/private?token=secret"]
        let identifier = UUID()
        let item = iOSHistoryItem(
            id: identifier, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcription: values[0], postProcessedTranscription: values[1], model: values[2],
            duration: 23, wordCount: 10, originPlatform: values[3], errorMessage: values[4]
        )
        let snapshot = IOSIssueReporter.snapshot(for: item)
        for report in [snapshot.full, snapshot.withoutDetails] {
            let surfaces = [report.title, report.body, report.jsonString, report.issueURL?.absoluteString ?? "",
                            IssueDiagnosticReport.attachmentFilename]
            for value in values + [identifier.uuidString, "1700000000"] {
                XCTAssertFalse(surfaces.contains { $0.contains(value) })
            }
        }
        let payload = try object(snapshot.full)
        XCTAssertEqual(payload["contextState"] as? String, "missingLegacyContext")
        XCTAssertNil(payload["context"])
        let failure = try XCTUnwrap((payload["failures"] as? [[String: Any]])?.first)
        XCTAssertEqual(failure["stage"] as? String, "unknown")
        XCTAssertEqual(failure["code"] as? String, "unknown")
        XCTAssertEqual(failure["domain"] as? String, "unknown")
        let model = try XCTUnwrap((payload["recordedModels"] as? [[String: Any]])?.first)
        XCTAssertEqual(model["classification"] as? String, "customOrUnknown")
        XCTAssertNil(model["identifier"])
    }

    func testCanonicalRecordedModelDoesNotBecomeEffectiveContextAndCanBeRemoved() throws {
        let identifier = "gladia/solaria-1-streaming"
        let item = iOSHistoryItem(transcription: "private text", model: identifier, duration: 1, wordCount: 2)
        let snapshot = IOSIssueReporter.snapshot(for: item)
        let payload = try object(snapshot.full)
        let model = try XCTUnwrap((payload["recordedModels"] as? [[String: Any]])?.first)
        XCTAssertEqual(model["classification"] as? String, "builtIn")
        XCTAssertEqual(model["identifier"] as? String, identifier)
        XCTAssertNil(payload["context"])
        XCTAssertEqual(payload["contextState"] as? String, "missingLegacyContext")
        XCTAssertTrue(snapshot.full.body.contains("Recorded model IDs are not verified handoffs"))
        XCTAssertNil(try object(snapshot.withoutDetails)["recordedModels"])
        XCTAssertFalse(snapshot.withoutDetails.body.contains(identifier))
        XCTAssertEqual((try object(IOSIssueReporter.failedRequest().full)["recordedModels"] as? [Any])?.count, 0)
    }

    func testMissingRowErrorDoesNotManufactureAFailureOrContext() throws {
        let item = iOSHistoryItem(transcription: "private text", model: "custom/private", duration: 1, wordCount: 2)
        let payload = try object(IOSIssueReporter.snapshot(for: item).full)
        XCTAssertEqual((payload["failures"] as? [Any])?.count, 0)
        XCTAssertNil(payload["context"])
        XCTAssertEqual(payload["contextState"] as? String, "missingLegacyContext")
    }

    func testOwnedFailureUsesOneImmutablePayloadForPreviewCopyURLAndExport() throws {
        let snapshot = IOSIssueReportSnapshot(
            context: .init(model: .project("gladia/solaria-1-streaming")),
            observedHandoff: .init(provenance: .observedHandoff, model: .project("openai/gpt-4o-transcribe")),
            requestFailure: .init(stage: .request)
        )
        let effects = IssueReportEffects()
        let controller = IOSIssueReportController(snapshot: snapshot, dependencies: .init(
            copy: { effects.copied.append($0); return true }, open: { effects.opened.append($0); return true }
        ))
        controller.copyDraft()
        XCTAssertEqual(effects.copied, [snapshot.full.body])
        let export = try XCTUnwrap(controller.beginExport())
        XCTAssertEqual(export.document.makeFileWrapper().regularFileContents, snapshot.full.jsonData)
        let url = try XCTUnwrap(snapshot.full.issueURL)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "body" })?.value, snapshot.full.body)
        controller.completeExport(export.id, outcome: .cancelled)
        controller.setIncludesDiagnostics(false)
        let removed = try object(controller.report)
        XCTAssertEqual(removed["contextState"] as? String, "userRemoved")
        XCTAssertNil(removed["context"])
        XCTAssertNil(removed["observedHandoff"])
        XCTAssertNil(removed["failures"])
    }

    func testConstructionAndRemovalHaveNoExternalEffects() throws {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertTrue(effects.opened.isEmpty)
        XCTAssertNil(controller.pendingExport)
        controller.setIncludesDiagnostics(false)
        let payload = try object(controller.report)
        XCTAssertEqual(payload["contextState"] as? String, "userRemoved")
        XCTAssertEqual(payload["omissionReason"] as? String, "userRemoved")
        XCTAssertNil(payload["failures"])
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertTrue(effects.opened.isEmpty)
    }

    func testCopyUsesExactCurrentlyPreviewedRemovedDraft() {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        controller.setIncludesDiagnostics(false)
        let previewed = controller.report.body
        controller.copyDraft()
        XCTAssertEqual(effects.copied, [previewed])
        XCTAssertEqual(controller.status, .copied)
        XCTAssertTrue(effects.opened.isEmpty)
        XCTAssertNil(controller.pendingExport)
    }

    func testCopyFailureIsFixedAndHasNoBrowserFallback() {
        let effects = IssueReportEffects()
        effects.copyResult = false
        let controller = makeController(effects)
        controller.copyDraft()
        XCTAssertEqual(controller.status, .copyFailed)
        XCTAssertEqual(controller.status?.message, "Could not copy the draft. Try again.")
        XCTAssertTrue(effects.opened.isEmpty)
    }

    func testBrowserUsesExactPreviewedURLAndMakesNoAttachmentClaim() async throws {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        controller.setIncludesDiagnostics(false)
        let previewed = try XCTUnwrap(controller.report.issueURL)
        await controller.openGitHub()
        XCTAssertEqual(effects.opened, [previewed])
        XCTAssertEqual(controller.status, .opened)
        XCTAssertTrue(controller.status?.message.contains("Nothing has been attached or submitted") == true)
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertNil(controller.pendingExport)
    }

    func testFailedBrowserOpenDoesNotAutomaticallyCopyOrExport() async {
        let effects = IssueReportEffects()
        effects.openResult = false
        let controller = makeController(effects)
        await controller.openGitHub()
        XCTAssertEqual(controller.status, .browserFailed)
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertNil(controller.pendingExport)
    }

    func testExportAdmissionFreezesBytesAndLocksOtherActions() async throws {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        controller.setIncludesDiagnostics(false)
        let previewed = controller.report.jsonData
        let export = try XCTUnwrap(controller.beginExport())
        XCTAssertEqual(export.document.data, previewed)
        XCTAssertEqual(export.document.makeFileWrapper().regularFileContents, previewed)
        XCTAssertEqual(IssueDiagnosticReport.attachmentFilename, "justspeaktoit-diagnostics.json")
        controller.setIncludesDiagnostics(true)
        controller.copyDraft()
        await controller.openGitHub()
        XCTAssertFalse(controller.includesDiagnostics)
        XCTAssertEqual(controller.report.jsonData, previewed)
        XCTAssertNil(controller.beginExport())
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertTrue(effects.opened.isEmpty)
        controller.completeExport(export.id, outcome: .saved)
        XCTAssertFalse(controller.isExporting)
        XCTAssertEqual(controller.status, .exported)
        XCTAssertTrue(controller.status?.message.contains("Attach the JSON yourself") == true)
    }

    func testExportCancellationAndFailureAreFixedAndAllowAnotherAttempt() throws {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        let cancelled = try XCTUnwrap(controller.beginExport())
        controller.completeExport(cancelled.id, outcome: .cancelled)
        XCTAssertEqual(controller.status, .exportCancelled)
        let failed = try XCTUnwrap(controller.beginExport())
        controller.completeExport(failed.id, outcome: .failed)
        XCTAssertEqual(controller.status?.message, "Could not save diagnostics. Try another destination.")
        XCTAssertFalse(controller.isExporting)
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertTrue(effects.opened.isEmpty)
    }

    func testStaleExportCompletionCannotSettleReplacementDocument() throws {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        let first = try XCTUnwrap(controller.beginExport())
        controller.completeExport(first.id, outcome: .cancelled)
        controller.setIncludesDiagnostics(false)
        let second = try XCTUnwrap(controller.beginExport())
        controller.completeExport(first.id, outcome: .saved)
        XCTAssertEqual(controller.pendingExport?.id, second.id)
        XCTAssertNil(controller.status)
        XCTAssertEqual(second.document.data, controller.report.jsonData)
        controller.completeExport(second.id, outcome: .saved)
        XCTAssertEqual(controller.status, .exported)
    }

    func testPreviewCancellationRefusesLaterEffectsWithoutRetractingAdmittedDocument() async throws {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        let admitted = try XCTUnwrap(controller.beginExport())
        let admittedData = admitted.document.data
        controller.cancel()
        controller.completeExport(admitted.id, outcome: .saved)
        controller.copyDraft()
        await controller.openGitHub()
        XCTAssertNil(controller.beginExport())
        XCTAssertNil(controller.status)
        XCTAssertTrue(effects.copied.isEmpty)
        XCTAssertTrue(effects.opened.isEmpty)
        XCTAssertEqual(admitted.document.data, admittedData, "System-admitted data is not retracted or deleted")
    }

    func testCancelledQueuedBrowserTaskHasNoExternalEffects() async {
        let effects = IssueReportEffects()
        let controller = makeController(effects)
        let task = Task { @MainActor in await controller.openGitHub() }
        task.cancel()
        await task.value
        XCTAssertTrue(effects.opened.isEmpty)
        XCTAssertNil(controller.status)
    }

    func testLateBrowserCompletionCannotPublishAfterPreviewCancellation() async throws {
        let effects = IssueReportEffects()
        let gate = IssueReportOpenGate()
        effects.gate = gate
        let controller = makeController(effects)
        let done = XCTestExpectation(description: "browser returned")
        let exited = XCTestExpectation(description: "browser task exited")
        let task = Task { @MainActor in
            await controller.openGitHub()
            done.fulfill()
            exited.fulfill()
        }
        addTeardownBlock { @MainActor in
            gate.release()
            task.cancel()
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(result, .completed)
        }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            return XCTFail("Browser operation was not admitted")
        }
        controller.cancel()
        gate.release()
        guard await XCTWaiter.fulfillment(of: [done], timeout: 2) == .completed else {
            return XCTFail("Owned browser operation did not return")
        }
        XCTAssertEqual(effects.opened.count, 1)
        XCTAssertNil(controller.status)
        XCTAssertFalse(controller.isOpening)
    }

    private func makeController(_ effects: IssueReportEffects) -> IOSIssueReportController {
        IOSIssueReportController(snapshot: IOSIssueReporter.failedRequest(), dependencies: .init(
            copy: { effects.copied.append($0); return effects.copyResult },
            open: { url in
                effects.opened.append(url)
                await effects.gate?.wait()
                return effects.openResult
            }
        ))
    }

    private func object(_ report: IssueDiagnosticReport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonData) as? [String: Any])
    }
}

@MainActor
private final class IssueReportEffects {
    var copied: [String] = []
    var opened: [URL] = []
    var copyResult = true
    var openResult = true
    var gate: IssueReportOpenGate?
}

@MainActor
private final class IssueReportOpenGate {
    let entered = XCTestExpectation(description: "browser admitted")
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        entered.fulfill()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
