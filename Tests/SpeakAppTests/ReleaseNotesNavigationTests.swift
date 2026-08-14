import SpeakCore
import XCTest

@testable import SpeakApp

/// Covers the macOS release-notes surface reached from Settings → About.
final class ReleaseNotesNavigationTests: XCTestCase {
    func testBundledNotesAreReadableFromTheAppTarget() {
        let catalog = ReleaseNotesCatalog.bundled

        XCTAssertFalse(catalog.isEmpty, "About → Release Notes needs offline notes shipped in the bundle")
        XCTAssertNotNil(catalog.latest?.blocks.first)
    }

    func testBrowserOpensOnTheInstalledVersionWhenItHasNotes() {
        let installed = ReleaseNotesCatalog.bundled.latest?.version ?? ""
        let browser = ReleaseNotesBrowser(installedVersion: installed)

        XCTAssertEqual(browser.selectedEntry?.version, installed)
        XCTAssertTrue(browser.isShowingInstalledVersion)
    }

    func testBrowserFallsBackToTheNewestNotesForAnUnreleasedBuild() {
        let browser = ReleaseNotesView.makeBrowser(bundle: Bundle(for: Self.self))

        XCTAssertNotNil(browser.selectedEntry, "The sheet must always open on some version")
        XCTAssertEqual(browser.entries.first?.version, ReleaseNotesCatalog.bundled.latest?.version)
    }

    func testEveryBundledVersionIsSelectableFromTheVersionList() {
        var browser = ReleaseNotesBrowser(installedVersion: ReleaseNotesCatalog.bundled.latest?.version ?? "")

        for entry in browser.entries {
            browser.select(version: entry.version)
            XCTAssertEqual(browser.selectedEntry?.version, entry.version)
            XCTAssertFalse(browser.otherEntries.contains { $0.version == entry.version })
        }
    }
}
