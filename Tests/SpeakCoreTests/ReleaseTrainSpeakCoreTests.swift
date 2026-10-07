import XCTest
@testable import SpeakCore

/// Release-train behaviour of SpeakCore types. `ReleaseTrain` itself is tested
/// in `SpeakWatchCoreTests` (issue #1123).
final class ReleaseTrainSpeakCoreTests: XCTestCase {
    func testAlphaCannotReadStableLegacyKeychainServices() {
        let config = SecureStorageConfiguration(
            service: "vault", legacyServices: ["old-vault"], accessGroup: "TEAM.shared", releaseTrain: .alpha
        )
        XCTAssertEqual(config.service, "vault.alpha")
        XCTAssertEqual(config.legacyServices, ["old-vault.alpha"])
        XCTAssertEqual(config.accessGroup, "TEAM.shared.alpha")
    }

    func testAlphaNotesDistinguishBuildsOfSameVersion() {
        let entries = [1, 2].map { build in
            ReleaseNoteEntry(version: "3.2.0", tag: "alpha-build-\(build)", publishedAt: "2026-09-09",
                             markdown: "Build \(build)", platform: .mac, train: .alpha, build: "1000.0.\(build)")
        }
        var browser = ReleaseNotesBrowser(catalog: .init(entries: entries), installedVersion: "3.2.0",
                                          platform: .mac, train: .alpha, installedBuild: "1000.0.2")
        XCTAssertTrue(browser.isShowingInstalledVersion)
        XCTAssertNotEqual(entries[0].displayTitle, entries[1].displayTitle)
        browser.select(version: entries[0].selectionKey)
        XCTAssertFalse(browser.isShowingInstalledVersion)
        XCTAssertEqual(browser.selectedEntry?.build, "1000.0.1")
    }
}
