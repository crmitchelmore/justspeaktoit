import XCTest
@testable import SpeakCore

final class AlphaReleaseNotesBrowserTests: XCTestCase {
    func testInstalledAlpha_matchesBuildWhenMarketingVersionIsShared() {
        let entries = ["42", "41"].map { build in
            ReleaseNoteEntry(version: "3.2.0", tag: "alpha-build-\(build)", publishedAt: "",
                             markdown: "Build \(build)", platform: .mac, train: .alpha, build: build)
        }
        var browser = ReleaseNotesBrowser(catalog: ReleaseNotesCatalog(entries: entries),
                                          installedVersion: "3.2.0", platform: .mac,
                                          train: .alpha, installedBuild: "41")
        XCTAssertEqual(browser.selectedEntry?.build, "41")
        XCTAssertEqual(browser.installedEntry?.build, "41")
        browser.select(version: entries[0].selectionKey)
        XCTAssertEqual(browser.installedEntry?.build, "41")
    }

    func testMissingAlphaBuild_doesNotClaimOtherBuildsNotesAreInstalled() {
        let entry = ReleaseNoteEntry(version: "3.2.0", tag: "alpha-build-42", publishedAt: "",
                                     markdown: "Newer", platform: .mac, train: .alpha, build: "42")
        let browser = ReleaseNotesBrowser(catalog: ReleaseNotesCatalog(entries: [entry]),
                                          installedVersion: "3.2.0", platform: .mac,
                                          train: .alpha, installedBuild: "41")
        XCTAssertNil(browser.installedEntry)
        XCTAssertFalse(browser.hasNotesForInstalledVersion)
        XCTAssertEqual(browser.selectedEntry, entry)
    }
}
