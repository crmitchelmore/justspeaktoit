import XCTest

@testable import SpeakCore

final class ReleaseNotesCatalogTests: XCTestCase {
    private let sampleJSON = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-08-08T09:10:00Z",
      "entries": [
        {
          "version": "2.44.0",
          "tag": "mac-v2.44.0",
          "publishedAt": "2026-08-07T21:31:50Z",
          "markdown": "## Overview\\n\\nSteadier live transcription."
        },
        {
          "version": "2.45.0",
          "tag": "mac-v2.45.0",
          "publishedAt": "2026-08-08T09:05:28Z",
          "markdown": "## Overview\\n\\nParakeet v3 arrives.\\n\\n### Highlights\\n\\n\
    - **Offline** transcription\\n  - 25 languages\\n"
        }
      ]
    }
    """

    private func makeCatalog() throws -> ReleaseNotesCatalog {
        try ReleaseNotesCatalog.decode(from: XCTUnwrap(sampleJSON.data(using: .utf8)))
    }

    // MARK: - Loading

    func testDecode_ordersEntriesNewestFirst() throws {
        let catalog = try makeCatalog()

        XCTAssertEqual(catalog.entries.map(\.version), ["2.45.0", "2.44.0"])
        XCTAssertEqual(catalog.latest?.version, "2.45.0")
        XCTAssertNotNil(catalog.generatedAt)
    }

    func testEntryLookup_ignoresTagPrefixes() throws {
        let catalog = try makeCatalog()

        XCTAssertEqual(catalog.entry(forVersion: "mac-v2.44.0")?.tag, "mac-v2.44.0")
        XCTAssertEqual(catalog.entry(forVersion: "v2.45.0")?.version, "2.45.0")
        XCTAssertEqual(catalog.entry(forVersion: " 2.45.0 ")?.version, "2.45.0")
        XCTAssertNil(catalog.entry(forVersion: "9.9.9"))
        XCTAssertNil(catalog.entry(forVersion: ""))
    }

    func testPlatformTracks_doNotOverwriteMatchingVersions() {
        let catalog = ReleaseNotesCatalog(entries: [
            ReleaseNoteEntry(
                version: "2.45.0",
                tag: "mac-v2.45.0",
                publishedAt: "2026-08-08T09:05:28Z",
                markdown: "macOS notes"
            ),
            ReleaseNoteEntry(
                version: "2.45.0",
                tag: "ios-v2.45.0",
                publishedAt: "2026-08-08T09:05:28Z",
                markdown: "iOS notes"
            )
        ])

        XCTAssertEqual(catalog.entry(forVersion: "2.45.0", platform: .mac)?.markdown, "macOS notes")
        XCTAssertEqual(catalog.entry(forVersion: "2.45.0", platform: .ios)?.markdown, "iOS notes")
        XCTAssertEqual(
            ReleaseNotesBrowser(catalog: catalog, installedVersion: "2.45.0", platform: .ios)
                .selectedEntry?.markdown,
            "iOS notes"
        )
    }

    func testDecode_readsPublicationDate() throws {
        let entry = try XCTUnwrap(makeCatalog().latest)
        let published = try XCTUnwrap(entry.publishedDate)

        XCTAssertEqual(published.timeIntervalSince1970, 1_786_179_928, accuracy: 1)
    }

    func testDecode_rejectsMalformedPayload() {
        let data = Data(#"{"entries": [{"tag": "mac-v1.0.0"}]}"#.utf8)

        XCTAssertThrowsError(try ReleaseNotesCatalog.decode(from: data))
    }

    func testBundledCatalog_isAvailableOfflineAndOrdered() {
        let catalog = ReleaseNotesCatalog.bundled

        XCTAssertFalse(catalog.isEmpty, "The app must ship release notes so they are readable offline")
        for platform in ReleaseNotesPlatform.allCases {
            let versions = catalog.entries(for: platform).map(\.version)
            XCTAssertEqual(versions, versions.sorted(by: ReleaseNotesVersion.isDescending))
        }
        for entry in catalog.entries {
            XCTAssertFalse(entry.markdown.isEmpty, "\(entry.version) shipped without notes")
            XCTAssertFalse(entry.blocks.isEmpty, "\(entry.version) produced no renderable content")
            XCTAssertFalse(entry.markdown.contains("<!--"), "\(entry.version) kept release-page HTML comments")
            XCTAssertFalse(
                entry.markdown.contains("/compare/"),
                "\(entry.version) kept the compare-URL footer, which is meaningless offline"
            )
        }
    }

    // MARK: - Versions

    func testVersionNormalisation() {
        XCTAssertEqual(ReleaseNotesVersion.normalised("mac-v2.45.0"), "2.45.0")
        XCTAssertEqual(ReleaseNotesVersion.normalised("ios-v1.2.3"), "1.2.3")
        XCTAssertEqual(ReleaseNotesVersion.normalised("V0.9.1"), "0.9.1")
        XCTAssertEqual(ReleaseNotesVersion.normalised("  2.0.0  "), "2.0.0")
    }

    func testVersionOrdering_usesNumericComponents() {
        XCTAssertTrue(ReleaseNotesVersion.isDescending("2.10.0", "2.9.0"))
        XCTAssertTrue(ReleaseNotesVersion.isDescending("2.41.1", "2.41.0"))
        XCTAssertFalse(ReleaseNotesVersion.isDescending("2.41.0", "2.41.1"))
        XCTAssertFalse(ReleaseNotesVersion.isDescending("2.41.0", "2.41.0"))
    }

    // MARK: - Markdown rendering

    func testMarkdownParsing_producesNativeBlocks() throws {
        let entry = try XCTUnwrap(makeCatalog().latest)
        let blocks = entry.blocks

        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph, .subheading, .bullet, .bullet])
        XCTAssertEqual(blocks.first?.text, "Overview")
        XCTAssertEqual(blocks.last?.indentLevel, 1)
        XCTAssertEqual(blocks[3].plainText, "Offline transcription")
    }

    func testMarkdownParsing_skipsHTMLCommentsAndBlankLines() {
        let markdown = """
        <!-- release-notes: model=gpt-5.6-luna -->

        ## Overview

        <!--
        multi-line comment
        -->
        Ships faster.
        """

        let blocks = ReleaseNotesMarkdown.blocks(from: markdown)

        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph])
        XCTAssertEqual(blocks.last?.text, "Ships faster.")
    }

    // MARK: - Navigation

    func testBrowser_selectsInstalledVersionByDefault() throws {
        let browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "2.44.0")

        XCTAssertEqual(browser.selectedEntry?.version, "2.44.0")
        XCTAssertTrue(browser.isShowingInstalledVersion)
        XCTAssertTrue(browser.hasNotesForInstalledVersion)
        XCTAssertEqual(browser.installedVersionTitle, "Version 2.44.0")
        XCTAssertEqual(browser.title(for: try XCTUnwrap(browser.installedEntry)), "Version 2.44.0 (installed)")
        XCTAssertEqual(browser.otherEntries.map(\.version), ["2.45.0"])
    }

    func testBrowser_fallsBackToLatestWhenInstalledVersionIsUnreleased() throws {
        let browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "2.46.0-dev")

        XCTAssertEqual(browser.selectedEntry?.version, "2.45.0")
        XCTAssertFalse(browser.hasNotesForInstalledVersion)
        XCTAssertFalse(browser.isShowingInstalledVersion)
        XCTAssertEqual(browser.otherEntries.map(\.version), ["2.44.0"])
        XCTAssertEqual(
            browser.installedVersionNotice,
            "Notes for the installed build (2.46.0-dev) are published with its release."
        )
    }

    func testBrowser_doesNotPromiseNotesForBuildsOlderThanTheCatalogue() throws {
        let browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "2.40.0")

        XCTAssertEqual(browser.selectedEntry?.version, "2.45.0")
        XCTAssertFalse(browser.hasNotesForInstalledVersion)
        XCTAssertEqual(browser.installedVersionNotice, "Showing the latest release notes.")
    }

    func testBrowser_dropsTheLatestNoticeWhenAnEarlierVersionIsSelected() throws {
        var browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "2.40.0")
        XCTAssertEqual(browser.installedVersionNotice, "Showing the latest release notes.")

        browser.select(version: "2.44.0")

        XCTAssertNil(
            browser.installedVersionNotice,
            "The latest notes are no longer on screen, so the notice would be untrue"
        )
    }

    func testBrowser_keepsTheUnreleasedNoticeWhileBrowsingEarlierVersions() throws {
        var browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "2.46.0-dev")

        browser.select(version: "2.44.0")

        XCTAssertEqual(
            browser.installedVersionNotice,
            "Notes for the installed build (2.46.0-dev) are published with its release.",
            "The installed build is still awaiting its own notes whichever version is being read"
        )
    }

    func testBrowser_noticeIsAbsentWhenTheInstalledVersionIsOnScreen() throws {
        let browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "2.44.0")

        XCTAssertNil(browser.installedVersionNotice)
    }

    func testBrowser_browsesEarlierVersionsAndReturnsToInstalled() throws {
        var browser = ReleaseNotesBrowser(catalog: try makeCatalog(), installedVersion: "mac-v2.45.0")
        XCTAssertEqual(browser.selectedEntry?.version, "2.45.0")

        browser.select(version: "mac-v2.44.0")
        XCTAssertEqual(browser.selectedEntry?.version, "2.44.0")
        XCTAssertFalse(browser.isShowingInstalledVersion)

        browser.select(version: "9.9.9")
        XCTAssertEqual(browser.selectedEntry?.version, "2.44.0", "Unknown versions must not clear the selection")

        browser.selectInstalledVersion()
        XCTAssertEqual(browser.selectedEntry?.version, "2.45.0")
        XCTAssertTrue(browser.isShowingInstalledVersion)
    }

    func testBrowser_handlesEmptyCatalog() {
        var browser = ReleaseNotesBrowser(catalog: .empty, installedVersion: "2.45.0")

        XCTAssertTrue(browser.isEmpty)
        XCTAssertNil(browser.selectedEntry)
        XCTAssertFalse(browser.hasNotesForInstalledVersion)
        XCTAssertNil(browser.installedVersionNotice, "An empty catalogue explains itself on screen")
        browser.selectInstalledVersion()
        XCTAssertNil(browser.selectedEntry)
    }

    func testBrowser_defaultsToBundledCatalogForTheInstalledBuild() {
        let browser = ReleaseNotesBrowser()

        XCTAssertEqual(
            browser.entries.map(\.version),
            ReleaseNotesCatalog.bundled.entries(for: .current).map(\.version)
        )
        XCTAssertEqual(browser.installedVersion, ReleaseNotesCatalog.installedVersion())
        XCTAssertNotNil(browser.selectedEntry, "A browsable catalogue must always open on some version")
    }
}
