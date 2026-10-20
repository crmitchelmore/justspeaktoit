import SpeakCore
import SpeakLinuxPlatform
import XCTest

final class LinuxPermissionsTests: XCTestCase {
    func testDetectedX11AndDevices_DoNotClaimCaptureOrInsertionPermission() throws {
        let items = LinuxPermissions.items(
            session: LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "x11", "DISPLAY": ":1"]),
            output: .init(), automation: false, runAtLogin: nil, microphoneWarning: nil
        )
        XCTAssertEqual(items.map(\.kind), [.microphone, .textInsertion, .automation, .notifications, .startup])
        XCTAssertEqual(try row(.microphone, items).status, .unknown)
        XCTAssertEqual(try row(.textInsertion, items).status, .unknown)
        XCTAssertTrue(try row(.textInsertion, items).detail.contains("does not send keys"))
        XCTAssertFalse(items.contains { $0.status == .granted })
    }

    func testWaylandFlatpak_ShowsDesktopApprovalAndSandboxGuidanceWithoutGrant() throws {
        let items = LinuxPermissions.items(
            session: LinuxDesktopSession(environment: [
                "XDG_SESSION_TYPE": "wayland", "XDG_CURRENT_DESKTOP": "GNOME", "FLATPAK_ID": "synthetic.app"
            ]),
            output: .init(), automation: true, runAtLogin: true, microphoneWarning: nil
        )
        XCTAssertTrue(try row(.microphone, items).detail.contains("Flatpak"))
        XCTAssertTrue(try row(.microphone, items).detail.contains("GNOME Settings"))
        XCTAssertTrue(try row(.textInsertion, items).detail.contains("does not request or renew access"))
        XCTAssertEqual(try row(.textInsertion, items).status, .unknown)
        XCTAssertEqual(try row(.automation, items).status, .granted)
        XCTAssertEqual(try row(.startup, items).status, .unknown)
        XCTAssertTrue(try row(.startup, items).detail.contains("not proof"))
    }

    func testClipboardOnly_DoesNotRequireInjectionOrLoseDeviceWarning() throws {
        let items = LinuxPermissions.items(
            session: LinuxDesktopSession(environment: [:]),
            output: .init(method: .clipboardOnly), automation: false, runAtLogin: false,
            microphoneWarning: "No input device"
        )
        XCTAssertEqual(try row(.textInsertion, items).status, .notApplicable)
        XCTAssertEqual(try row(.microphone, items).status, .warning)
        XCTAssertTrue(try row(.microphone, items).detail.contains("No input device"))
        XCTAssertEqual(try row(.notifications, items).status, .unknown)
    }

    func testUnknownDesktopAndKDE_HaveActionableNonGNOMEGuidance() throws {
        for environment in [[:], ["XDG_SESSION_TYPE": "wayland", "XDG_CURRENT_DESKTOP": "KDE"]] {
            let items = LinuxPermissions.items(
                session: LinuxDesktopSession(environment: environment), output: .init(),
                automation: false, runAtLogin: nil, microphoneWarning: nil
            )
            XCTAssertFalse(try row(.microphone, items).detail.contains("GNOME"))
            XCTAssertEqual(try row(.microphone, items).remediationTitle, "Open General")
            XCTAssertEqual(try row(.automation, items).status, .off)
        }
    }

    private func row(_ kind: DesktopPermissionKind, _ items: [DesktopPermissionItem]) throws -> DesktopPermissionItem {
        try XCTUnwrap(items.first { $0.kind == kind })
    }
}
