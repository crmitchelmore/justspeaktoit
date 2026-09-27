import Foundation
import XCTest
@testable import SpeakCore

/// Linux application matchers beside the macOS and Windows ones: an exact
/// executable path or an X11 window class, each evaluated only on Linux, and
/// both kept intact by the other platforms' edits.
final class DictationProfileLinuxMatcherTests: XCTestCase {
    private var editorProfile: DictationProfile {
        DictationProfile(
            name: "Editor",
            matchers: [.bundleID("com.apple.TextEdit"), .windowsExecutablePath(#"C:\Apps\Editor.exe"#)]
        ).replacingLinuxApplications(["/usr/bin/gedit", "org.gnome.TextEditor"])
    }

    func testLinesBecomePathOrWindowClassMatchers() {
        XCTAssertEqual(DictationProfileMatcher.linuxApplication(" /usr/bin/gedit ")?.kind, .linuxExecutablePath)
        XCTAssertEqual(DictationProfileMatcher.linuxApplication("firefox")?.kind, .linuxWindowClass)
        XCTAssertNil(DictationProfileMatcher.linuxApplication("   "))
        XCTAssertEqual(editorProfile.linuxApplications, ["/usr/bin/gedit", "org.gnome.TextEditor"])
    }

    func testExactPathsAndCaseInsensitiveWindowClassesMatch() {
        let resolver = ProfileResolver(profiles: [editorProfile])
        XCTAssertEqual(resolver.profile(forLinuxExecutablePath: "/usr/bin/gedit", windowClass: nil)?.name, "Editor")
        XCTAssertEqual(
            resolver.profile(forLinuxExecutablePath: nil, windowClass: "ORG.GNOME.TEXTEDITOR")?.name, "Editor"
        )
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: "/usr/bin/GEDIT", windowClass: nil),
                     "Linux paths are case-sensitive")
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: "gedit", windowClass: nil),
                     "A bare name is not a path and never matches a path matcher")
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: nil, windowClass: nil),
                     "Wayland reports neither, so the app's settings apply")
    }

    func testOtherPlatformsIgnoreLinuxMatchersAndKeepThem() {
        let profile = editorProfile
        let resolver = ProfileResolver(profiles: [profile])
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: "/usr/bin/gedit"))
        XCTAssertNil(resolver.profile(forBundleID: "org.gnome.TextEditor"))
        let windowsEdit = profile.replacingWindowsExecutablePaths([#"C:\Other\Editor.exe"#])
        XCTAssertEqual(windowsEdit.linuxApplications, profile.linuxApplications)
        let linuxEdit = profile.replacingLinuxApplications(["kate"])
        XCTAssertEqual(linuxEdit.windowsExecutablePaths, [#"C:\Apps\Editor.exe"#])
        XCTAssertTrue(linuxEdit.matchers.contains(.bundleID("com.apple.TextEdit")))
    }

    func testValidationRejectsLinesThatCouldNeverMatch() {
        let invalid = DictationProfile(name: "Bad").replacingLinuxApplications(
            ["usr/bin/gedit", "/usr/bin/../gedit", "two words", "/usr/bin/"]
        )
        let issues = DictationProfileValidator.issues(for: invalid)
        XCTAssertEqual(issues.count, 4)
        XCTAssertTrue(issues.contains(.invalidLinuxApplication(value: "usr/bin/gedit")),
                      "A relative path is neither a full path nor a window class")
        XCTAssertTrue(issues.contains(.invalidLinuxApplication(value: "/usr/bin/../gedit")))
        XCTAssertTrue(issues.contains(.invalidLinuxApplication(value: "two words")))
        XCTAssertTrue(issues.contains(.invalidLinuxApplication(value: "/usr/bin/")))
        XCTAssertTrue(DictationProfileValidator.issues(for: editorProfile).isEmpty)
    }

    func testLinuxMatchersSurviveTheStoredFormat() throws {
        let data = try DictationProfile.encodeList([editorProfile])
        let decoded = try DictationProfile.decodeList(data)
        XCTAssertEqual(decoded.first?.linuxApplications, editorProfile.linuxApplications)
        XCTAssertEqual(decoded.first?.windowsExecutablePaths, [#"C:\Apps\Editor.exe"#])
    }
}
