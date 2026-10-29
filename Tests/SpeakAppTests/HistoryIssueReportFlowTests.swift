import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class HistoryIssueReportFlowTests: XCTestCase {
    func testPreviewConstructionAndDismissalHaveNoExternalEffects() {
        let fixture = Fixture()
        do {
            let controller = fixture.controller()
            XCTAssertEqual(controller.report.jsonData, fixture.report.jsonData)
            XCTAssertNil(controller.status)
            controller.cancel()
            controller.copyDraft()
            controller.openGitHub()
        }
        XCTAssertEqual(fixture.effects, [])
    }

    func testRemovingDetailsReplacesEveryActionPayloadWithExactVisibleOmissionReport() async {
        let fixture = Fixture()
        fixture.destination = URL(fileURLWithPath: "/owned-test-output/selected.json")
        let controller = fixture.controller()
        controller.setIncludesDiagnostics(false)
        XCTAssertEqual(fixture.effects, [])
        XCTAssertFalse(controller.includesDiagnostics)
        XCTAssertEqual(controller.report.jsonData, fixture.reportWithoutDetails.jsonData)
        XCTAssertNotEqual(controller.report.jsonData, fixture.report.jsonData)
        XCTAssertEqual(controller.report.body, fixture.reportWithoutDetails.body)
        controller.copyDraft()
        controller.openGitHub()
        await controller.exportJSON()
        XCTAssertEqual(fixture.effects, ["copy", "open", "choose", "write"])
        XCTAssertEqual(fixture.copiedText, controller.report.body)
        XCTAssertEqual(fixture.openedURL, controller.report.issueURL)
        XCTAssertEqual(fixture.writtenData, Data(controller.report.jsonString.utf8))
        controller.setIncludesDiagnostics(true)
        XCTAssertEqual(controller.report.jsonData, fixture.report.jsonData)
        XCTAssertEqual(controller.report.body, fixture.report.body)
        XCTAssertNil(controller.status)
    }

    func testCancelledSavePanelDoesNotWriteCopyOrOpen() async {
        let fixture = Fixture()
        let controller = fixture.controller()
        await controller.exportJSON()
        XCTAssertEqual(fixture.effects, ["choose"])
        XCTAssertNil(controller.status)
        XCTAssertFalse(controller.isExporting)
        XCTAssertEqual(fixture.suggestedFilename, "justspeaktoit-diagnostics.json")
    }

    func testDismissalWhileChoosingDestinationPreventsLateWrite() async {
        let fixture = Fixture()
        let controller = fixture.controller()
        fixture.onChoose = { controller.cancel() }
        fixture.destination = URL(fileURLWithPath: "/owned-test-output/selected.json")
        await controller.exportJSON()
        XCTAssertEqual(fixture.effects, ["choose"])
        XCTAssertNil(controller.status)
        XCTAssertFalse(controller.isExporting)
    }

    func testExportWritesExactFrozenPreviewBytesOnlyToExplicitDestination() async {
        let fixture = Fixture()
        fixture.destination = URL(fileURLWithPath: "/owned-test-output/selected.json")
        let controller = fixture.controller()
        await controller.exportJSON()
        XCTAssertEqual(fixture.effects, ["choose", "write"])
        XCTAssertEqual(fixture.writtenData, controller.report.jsonData)
        XCTAssertEqual(fixture.writtenData, Data(controller.report.jsonString.utf8))
        XCTAssertEqual(fixture.writtenURL, fixture.destination)
        XCTAssertEqual(controller.status, .exported)
    }

    func testSavePanelCannotChangeFrozenBytesAfterExportBegins() async {
        let fixture = Fixture()
        fixture.destination = URL(fileURLWithPath: "/owned-test-output/selected.json")
        let controller = fixture.controller()
        fixture.onChoose = { controller.setIncludesDiagnostics(false) }
        await controller.exportJSON()
        XCTAssertTrue(controller.includesDiagnostics)
        XCTAssertEqual(fixture.writtenData, fixture.report.jsonData)
        XCTAssertEqual(controller.report.jsonData, fixture.report.jsonData)
    }

    func testExportFailureUsesFixedMessageWithoutPathOrRawError() async {
        let fixture = Fixture()
        fixture.destination = URL(fileURLWithPath: "/PRIVATE_DESTINATION/token-canary.json")
        fixture.failWrite = true
        let controller = fixture.controller()
        await controller.exportJSON()
        XCTAssertEqual(fixture.effects, ["choose", "write"])
        XCTAssertEqual(controller.status, .exportFailed)
        XCTAssertEqual(controller.status?.message, "Could not save diagnostics. Try another destination.")
        XCTAssertFalse(controller.status?.message.contains("PRIVATE") == true)
        XCTAssertFalse(controller.status?.message.contains("token-canary") == true)
    }

    func testCopyRequiresExplicitActionAndCopiesExactPreviewDraft() {
        let fixture = Fixture()
        let controller = fixture.controller()
        XCTAssertEqual(fixture.effects, [])
        controller.copyDraft()
        XCTAssertEqual(fixture.effects, ["copy"])
        XCTAssertEqual(fixture.copiedText, controller.report.body)
        XCTAssertEqual(controller.status, .copied)
    }

    func testBrowserFailureNeverFallsBackToCopyOrExport() {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.openGitHub()
        XCTAssertEqual(fixture.effects, ["open"])
        XCTAssertEqual(fixture.openedURL, controller.report.issueURL)
        XCTAssertEqual(controller.status, .browserFailed)
    }

    func testBrowserSuccessDoesNotClaimAttachmentOrSubmission() {
        let fixture = Fixture()
        fixture.openSucceeds = true
        let controller = fixture.controller()
        controller.openGitHub()
        XCTAssertEqual(fixture.effects, ["open"])
        XCTAssertEqual(controller.status, .opened)
        XCTAssertEqual(controller.status?.message, "GitHub opened. Nothing has been attached or submitted.")
    }
}

@MainActor
private final class Fixture {
    let report = IssueDiagnosticReport(failures: [.init(stage: .output, code: .timeout)])
    let reportWithoutDetails = IssueDiagnosticReport(omittedSections: Set(IssueDiagnosticReport.Section.allCases))
    var effects: [String] = []
    var destination: URL?
    var suggestedFilename: String?
    var writtenData: Data?
    var writtenURL: URL?
    var copiedText: String?
    var openedURL: URL?
    var failWrite = false
    var openSucceeds = false
    var onChoose: (() -> Void)?

    func controller() -> HistoryIssueReportController {
        HistoryIssueReportController(report: report, reportWithoutDetails: reportWithoutDetails, dependencies: .init(
            chooseDestination: { filename in
                self.effects.append("choose")
                self.suggestedFilename = filename
                let onChoose = self.onChoose
                self.onChoose = nil
                onChoose?()
                return self.destination
            },
            write: { data, url in
                self.effects.append("write")
                if self.failWrite {
                    throw NSError(domain: "PRIVATE_ERROR_token-canary", code: 1)
                }
                self.writtenData = data
                self.writtenURL = url
            },
            copy: { text in
                self.effects.append("copy")
                self.copiedText = text
            },
            open: { url in
                self.effects.append("open")
                self.openedURL = url
                return self.openSucceeds
            }
        ))
    }
}
