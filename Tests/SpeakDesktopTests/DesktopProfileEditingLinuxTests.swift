import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// The Linux profile editor edits Linux applications only, and names the
/// other platforms' matchers without touching them.
final class DesktopProfileEditingLinuxTests: XCTestCase {
    private let linux = DesktopProfileEditing.Catalogue(capabilities: .shared, matchers: .linux)
    private let windows = DesktopProfileEditing.Catalogue(capabilities: .shared)
    private let notepad = #"C:\Windows\System32\notepad.exe"#

    private let stored = DictationProfile(
        name: "Notes",
        matchers: [.windowsExecutablePath(#"C:\Windows\System32\notepad.exe"#), .bundleID("com.apple.Notes")]
    ).replacingLinuxApplications(["/usr/bin/gedit"])

    func testTheLinuxDraftShowsLinuxApplicationsAndNotesTheOthers() {
        let draft = DesktopProfileEditing.draft(for: stored, catalogue: linux)
        XCTAssertEqual(draft.executablePaths, ["/usr/bin/gedit"])
        XCTAssertTrue(draft.notes.contains { $0.contains("Windows apps") && $0.contains(notepad) })
        XCTAssertTrue(draft.notes.contains { $0.contains("com.apple.Notes") })

        let windowsDraft = DesktopProfileEditing.draft(for: stored, catalogue: windows)
        XCTAssertEqual(windowsDraft.executablePaths, [notepad])
        XCTAssertTrue(windowsDraft.notes.contains { $0.contains("Linux apps") && $0.contains("/usr/bin/gedit") })
    }

    func testSavingALinuxDraftReplacesOnlyLinuxMatchers() throws {
        var draft = DesktopProfileEditing.draft(for: stored, catalogue: linux)
        draft.executablePaths = ["  kate  ", "", "/usr/bin/gedit", "KATE"]
        let merged = try DesktopProfileEditing.merge([draft], into: [stored], catalogue: linux).get()
        let profile = try XCTUnwrap(merged.first)
        XCTAssertEqual(profile.linuxApplications, ["kate", "/usr/bin/gedit"], "Blank and repeated classes are dropped")
        XCTAssertEqual(profile.windowsExecutablePaths, [notepad])
        XCTAssertTrue(profile.matchers.contains(.bundleID("com.apple.Notes")))
        XCTAssertEqual(profile.id, stored.id)
    }

    func testAnInvalidLinuxLineIsRefusedWithAReadableReason() {
        var draft = DesktopProfileEditing.draft(for: stored, catalogue: linux)
        draft.executablePaths = ["/opt/app/../bin"]
        switch DesktopProfileEditing.merge([draft], into: [stored], catalogue: linux) {
        case .success: XCTFail("A path with .. must be refused")
        case .failure(let failure): XCTAssertTrue(failure.message.contains("/usr/bin/gedit"), failure.message)
        }
    }
}
