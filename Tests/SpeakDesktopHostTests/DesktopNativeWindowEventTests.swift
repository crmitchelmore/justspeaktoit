import XCTest
@testable import SpeakDesktopHost

final class DesktopNativeWindowEventTests: XCTestCase {
    private typealias WindowsCode = DesktopNativeWindowEventCode<DesktopNativeWindowsEvent>
    private typealias LinuxCode = DesktopNativeWindowEventCode<DesktopNativeLinuxEvent>

    func testDecode_routesComparisonRangesBeforeAnyNamedEvent() {
        for raw: Int32 in [100, 109, 120, 129] {
            XCTAssertEqual(WindowsCode(raw), .comparison(raw))
            XCTAssertEqual(LinuxCode(raw), .comparison(raw))
        }
        XCTAssertEqual(WindowsCode(110), .shared(.quickVoice))
        XCTAssertEqual(LinuxCode(119), .unknown(119))
    }

    func testDecode_separatesSharedAndHostEvents() {
        XCTAssertEqual(WindowsCode(1), .shared(.toggleRecording))
        XCTAssertEqual(LinuxCode(1), .shared(.toggleRecording))
        XCTAssertEqual(WindowsCode(24), .host(.readAloud))
        XCTAssertEqual(LinuxCode(40), .host(.readAloud))
        // Each host's own numbers mean nothing to the other.
        XCTAssertEqual(LinuxCode(24), .unknown(24))
        XCTAssertEqual(WindowsCode(40), .unknown(40))
    }

    func testDecode_keepsUnknownNumbersAndTheirRawValue() {
        for raw: Int32 in [0, -1, 999, Int32.max] {
            XCTAssertEqual(WindowsCode(raw), .unknown(raw))
            XCTAssertEqual(WindowsCode(raw).rawValue, raw)
        }
    }

    func testDecode_roundTripsEveryNamedEvent() {
        for event in DesktopNativeWindowEvent.allCases {
            XCTAssertEqual(LinuxCode(event.rawValue).rawValue, event.rawValue)
            XCTAssertFalse(WindowsCode.isComparison(event.rawValue), "\(event)")
        }
        for event in DesktopNativeWindowsEvent.allCases { XCTAssertEqual(WindowsCode(event.rawValue), .host(event)) }
    }

    /// Linux's recordings-location constant shares 98 with Restore; the shared
    /// event wins, matching the window's dispatch before the enum existed.
    func testDecode_linuxRecordingsLocationIsShadowedByRestore() {
        XCTAssertEqual(
            DesktopNativeLinuxEvent.recordingsLocation.rawValue, DesktopNativeWindowEvent.migrationRestore.rawValue
        )
        XCTAssertEqual(LinuxCode(98), .shared(.migrationRestore))
    }

    func testIssueReportActions_areTheTicketCarryingEvents() {
        let actions = DesktopNativeWindowEvent.allCases.filter(\.isIssueReportAction)
        XCTAssertEqual(
            actions, [.issueReportInclude, .issueReportCopy, .issueReportSave, .issueReportOpen, .issueReportClose]
        )
    }
}
