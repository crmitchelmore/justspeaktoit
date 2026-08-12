#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Covers the iOS release-notes surface reached from Settings → About.
final class ReleaseNotesNavigationTests: XCTestCase {
    func testBundledNotesAreReadableFromTheIOSTarget() {
        let catalog = ReleaseNotesCatalog.bundled

        XCTAssertFalse(catalog.isEmpty, "About → Release Notes needs offline notes shipped in the bundle")
        XCTAssertNotNil(catalog.latest?.blocks.first)
    }

    func testBrowserOpensOnTheInstalledVersionWhenItHasNotes() {
        let installed = ReleaseNotesCatalog.bundled.latest?.version ?? ""
        let browser = ReleaseNotesBrowser(installedVersion: installed)

        XCTAssertEqual(browser.selectedEntry?.version, installed)
        XCTAssertTrue(browser.isShowingInstalledVersion)
        XCTAssertFalse(browser.otherEntries.contains { $0.version == installed })
    }

    func testBrowserFallsBackToTheNewestNotesForAnUnreleasedBuild() {
        let browser = ReleaseNotesView.makeBrowser(bundle: Bundle(for: Self.self))

        XCTAssertNotNil(browser.selectedEntry, "The screen must always open on some version")
        XCTAssertEqual(browser.entries.first?.version, ReleaseNotesCatalog.bundled.latest?.version)
    }

    func testEarlierVersionsRemainBrowsable() {
        let browser = ReleaseNotesBrowser(installedVersion: ReleaseNotesCatalog.bundled.latest?.version ?? "")

        XCTAssertEqual(browser.otherEntries.count, max(0, browser.entries.count - 1))
        for entry in browser.otherEntries {
            XCTAssertFalse(entry.blocks.isEmpty, "\(entry.version) has no content to push onto the stack")
        }
    }
}
#endif
