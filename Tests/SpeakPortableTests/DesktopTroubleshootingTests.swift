import XCTest
@testable import SpeakCore

final class DesktopTroubleshootingTests: XCTestCase {
    private func input(
        model: String = "openai/gpt-4o-mini", enabled: Bool = true,
        credential: DesktopTroubleshooting.Credential = .missing, restore: Bool = true
    ) -> DesktopTroubleshooting.Input {
        .init(
            postProcessing: .init(enabled: enabled, model: model, credential: credential),
            shortcutName: "Ctrl+Space", shortcutInstructions: "Hold Ctrl+Space to record.", restoreClipboard: restore
        )
    }

    func testCanonicalChecks_AppearInOrderWithoutDuplicateIdentifiers() {
        let findings = DesktopTroubleshooting.findings(input())
        XCTAssertEqual(findings.map(\.id), DesktopTroubleshooting.Check.allCases.map(\.rawValue))
        XCTAssertEqual(Set(findings.map(\.id)).count, findings.count)
        XCTAssertEqual(findings[1].title, "Shortcut: Ctrl+Space")
        XCTAssertEqual(findings[1].detail, "Hold Ctrl+Space to record.")
    }

    func testLocalDisabledAndCredentialedProcessing_DoesNotReportMissingKey() {
        for model in ["apple/intelligence", "LOCAL/imported/model", "on-device"] {
            XCTAssertFalse(DesktopTroubleshooting.requiresCredential(enabled: true, model: model))
            XCTAssertFalse(DesktopTroubleshooting.findings(input(model: model)).contains {
                $0.id == "postprocessing-api-key"
            })
        }
        for value in [input(enabled: false), input(credential: .available)] {
            XCTAssertFalse(DesktopTroubleshooting.findings(value).contains { $0.id == "postprocessing-api-key" })
        }
    }

    func testUnavailableCredential_IsNotMissingAndHasNoDestructiveFix() throws {
        let finding = try XCTUnwrap(DesktopTroubleshooting.findings(input(credential: .unavailable)).first)
        XCTAssertEqual(finding.id, "postprocessing-api-key")
        XCTAssertEqual(finding.severity, .warning)
        XCTAssertEqual(finding.destination, .apiKeys)
        XCTAssertNil(finding.fix)
        let missing = try XCTUnwrap(DesktopTroubleshooting.findings(input()).first)
        XCTAssertEqual(missing.severity, .issue)
        XCTAssertEqual(missing.fix, .disablePostProcessing)
    }

    func testClipboardFix_OnlyOfferedWhenRestorationIsEnabled() throws {
        let restored = try XCTUnwrap(DesktopTroubleshooting.findings(input()).last)
        XCTAssertEqual(restored.fix, .keepTranscriptOnClipboard)
        XCTAssertEqual(restored.severity, .warning)
        let kept = try XCTUnwrap(DesktopTroubleshooting.findings(input(restore: false)).last)
        XCTAssertNil(kept.fix)
        XCTAssertEqual(kept.severity, .ok)
        XCTAssertEqual(kept.destination, .general)
    }
}
