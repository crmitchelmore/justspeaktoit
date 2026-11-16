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
        XCTAssertEqual(WindowsCode(170), .shared(.systemResourceRelease))
        XCTAssertEqual(LinuxCode(171), .shared(.systemResourcesReleaseAll))
        XCTAssertEqual(WindowsCode(180), .shared(.rawConfiguration))
        XCTAssertEqual(LinuxCode(180), .shared(.rawConfiguration))
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

    /// Every host-only event decodes as itself: no host number may collide
    /// with a shared event or a forwarded comparison event.
    func testDecode_hostEventsAreDistinctFromSharedAndComparisonEvents() {
        let shared = Set(DesktopNativeWindowEvent.allCases.map(\.rawValue))
        for event in DesktopNativeLinuxEvent.allCases {
            XCTAssertFalse(shared.contains(event.rawValue), "\(event)")
            XCTAssertEqual(LinuxCode(event.rawValue), .host(event))
        }
        for event in DesktopNativeWindowsEvent.allCases {
            XCTAssertFalse(shared.contains(event.rawValue), "\(event)")
            XCTAssertEqual(WindowsCode(event.rawValue), .host(event))
        }
    }

    func testDecode_linuxRecordingsLocationAndRestoreDispatchSeparately() {
        XCTAssertEqual(LinuxCode(DesktopNativeLinuxEvent.recordingsLocation.rawValue), .host(.recordingsLocation))
        XCTAssertEqual(LinuxCode(DesktopNativeWindowEvent.migrationRestore.rawValue), .shared(.migrationRestore))
    }

    func testIssueReportActions_areTheTicketCarryingEvents() {
        let actions = DesktopNativeWindowEvent.allCases.filter(\.isIssueReportAction)
        XCTAssertEqual(
            actions, [.issueReportInclude, .issueReportCopy, .issueReportSave, .issueReportOpen, .issueReportClose]
        )
    }
}
