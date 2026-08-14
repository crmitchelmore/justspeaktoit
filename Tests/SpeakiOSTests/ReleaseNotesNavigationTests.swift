#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Covers the iOS release-notes surface reached from Settings → About.
final class ReleaseNotesNavigationTests: XCTestCase {
    private let iosCatalog = ReleaseNotesCatalog(entries: [
        ReleaseNoteEntry(
            version: "1.2.0",
            tag: "ios-v1.2.0",
            publishedAt: "2026-08-14T00:00:00Z",
            markdown: "## Overview\n\nCurrent iOS notes."
        ),
        ReleaseNoteEntry(
            version: "1.1.0",
            tag: "ios-v1.1.0",
            publishedAt: "2026-08-07T00:00:00Z",
            markdown: "## Overview\n\nEarlier iOS notes."
        ),
    ])

    func testBundledResourceIsReadableFromTheIOSTarget() {
        let catalog = ReleaseNotesCatalog.bundled

        XCTAssertFalse(catalog.entries.isEmpty, "SpeakCore must expose its offline resource to the iOS target")
        XCTAssertTrue(catalog.entries.allSatisfy { !$0.blocks.isEmpty })
    }

    func testBrowserOpensOnTheInstalledVersionWhenItHasNotes() {
        let browser = ReleaseNotesBrowser(catalog: iosCatalog, installedVersion: "1.2.0", platform: .ios)

        XCTAssertEqual(browser.selectedEntry?.version, "1.2.0")
        XCTAssertTrue(browser.isShowingInstalledVersion)
        XCTAssertFalse(browser.otherEntries.contains { $0.version == "1.2.0" })
    }

    func testBrowserFallsBackToTheNewestNotesForAnUnreleasedBuild() {
        let browser = ReleaseNotesBrowser(catalog: iosCatalog, installedVersion: "1.3.0", platform: .ios)

        XCTAssertNotNil(browser.selectedEntry, "The screen must always open on some version")
        XCTAssertEqual(browser.entries.first?.version, "1.2.0")
    }

    func testEarlierVersionsRemainBrowsable() {
        let browser = ReleaseNotesBrowser(catalog: iosCatalog, installedVersion: "1.2.0", platform: .ios)

        XCTAssertEqual(browser.otherEntries.count, max(0, browser.entries.count - 1))
        for entry in browser.otherEntries {
            XCTAssertFalse(entry.blocks.isEmpty, "\(entry.version) has no content to push onto the stack")
        }
    }
}
#endif
