import Foundation
import XCTest
import SpeakDesktop
@testable import SpeakLinuxPlatform

/// The XDG autostart entry behind General › Launch at login outside Flatpak.
final class LinuxLoginItemTests: XCTestCase {
    private var config: URL!
    private var environment: [String: String] { ["XDG_CONFIG_HOME": config.path, "HOME": "/nonexistent"] }
    private var entry: URL { config.appendingPathComponent("autostart/com.justspeaktoit.JustSpeakToIt.desktop") }

    override func setUp() {
        config = FileManager.default.temporaryDirectory.appendingPathComponent("login-item-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: config)
    }

    func testTheEntryFollowsXDGConfigHomeAndFallsBackToHome() {
        XCTAssertEqual(LinuxLoginItem.entryURL(environment: environment), entry)
        XCTAssertEqual(
            LinuxLoginItem.entryURL(environment: ["HOME": "/home/ada", "XDG_CONFIG_HOME": "relative"]).path,
            "/home/ada/.config/autostart/com.justspeaktoit.JustSpeakToIt.desktop"
        )
    }

    func testExecQuotesReservedCharactersAndEscapesTheValue() {
        XCTAssertEqual(
            LinuxLoginItem.execValue(["/usr/bin/justspeaktoit", "--background"]), "/usr/bin/justspeaktoit --background"
        )
        XCTAssertEqual(LinuxLoginItem.execValue(["/opt/Just Speak/app"]), #""/opt/Just Speak/app""#)
        XCTAssertEqual(LinuxLoginItem.execValue(["/opt/100%/app"]), "/opt/100%%/app")
        XCTAssertEqual(LinuxLoginItem.execValue([#"/opt/$HOME"it"#]), #""/opt/\\$HOME\\"it""#)
        // Quoting escapes the backslash once, the string value escapes both again.
        XCTAssertEqual(LinuxLoginItem.execValue([#"/opt/a\b"#]), #""/opt/a\\\\b""#)
        XCTAssertEqual(LinuxLoginItem.execValue([""]), #""""#)
    }

    func testTurningItOnWritesAnEntryThatStartsMinimised() throws {
        XCTAssertEqual(LinuxLoginItem.state(environment: environment), .disabled)
        let reached = try LinuxLoginItem.setEnabled(true, executable: "/opt/Just Speak/justspeaktoit",
                                                    environment: environment)
        XCTAssertEqual(reached, .enabled)
        let written = try String(contentsOf: entry, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("[Desktop Entry]\nType=Application\n"))
        XCTAssertTrue(written.contains("\nExec=\"/opt/Just Speak/justspeaktoit\" --background\n"))
        XCTAssertTrue(written.contains("\nIcon=com.justspeaktoit.JustSpeakToIt\n"))
        XCTAssertEqual(DesktopLoginItem.launchArgument, "--background")

        let removed = try LinuxLoginItem.setEnabled(false, executable: "/unused", environment: environment)
        XCTAssertEqual(removed, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
        let again = try LinuxLoginItem.setEnabled(false, executable: "/unused", environment: environment)
        XCTAssertEqual(again, .disabled, "removing a missing entry is not an error")
    }

    func testTheDesktopsOwnSwitchesTurnItOff() throws {
        _ = try LinuxLoginItem.setEnabled(true, executable: "/usr/bin/justspeaktoit", environment: environment)
        for disabled in ["Hidden=true", "X-GNOME-Autostart-enabled=false"] {
            let edited = try String(contentsOf: entry, encoding: .utf8) + "\(disabled)\n"
            try edited.write(to: entry, atomically: true, encoding: .utf8)
            XCTAssertEqual(LinuxLoginItem.state(environment: environment), .disabled, disabled)
            let restored = try LinuxLoginItem.setEnabled(true, executable: "/usr/bin/justspeaktoit",
                                                         environment: environment)
            XCTAssertEqual(restored, .enabled, "turning it on again rewrites the entry")
        }
        let otherGroup = LinuxLoginItem.autostartEntry(executable: "/usr/bin/justspeaktoit")
            + "[Desktop Action Quit]\nHidden=true\n"
        XCTAssertTrue(LinuxLoginItem.isEnabled(entry: otherGroup))
    }

    func testADanglingLinkIsRemoved() throws {
        let folder = entry.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "/nonexistent/entry")
        XCTAssertEqual(LinuxLoginItem.state(environment: environment), .disabled)
        _ = try LinuxLoginItem.setEnabled(false, executable: "/unused", environment: environment)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path))
    }
}
