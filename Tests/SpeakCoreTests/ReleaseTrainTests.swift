import XCTest
@testable import SpeakCore

final class ReleaseTrainTests: XCTestCase {
    func testStablePersistenceNamesRemainCompatible() {
        XCTAssertEqual(ReleaseTrain.stable.supportDirectory, "SpeakApp")
        XCTAssertEqual(ReleaseTrain.stable.iosAppGroup, "group.com.justspeaktoit.ios")
        XCTAssertEqual(
            ReleaseTrain.stable.namespace("com.github.speakapp.credentials"), "com.github.speakapp.credentials"
        )
        XCTAssertEqual(ReleaseTrain.stable.feedURL, "https://justspeaktoit.com/appcast.xml")
    }

    func testAlphaSeparatesEveryCatalogueNamespace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/SpeakCore/Resources/ReleaseTrains.json"))
        let catalogue = try JSONDecoder().decode([String: [String: String]].self, from: data)
        let stable = try XCTUnwrap(catalogue["stable"])
        let alpha = try XCTUnwrap(catalogue["alpha"])
        XCTAssertEqual(Set(stable.keys), Set(alpha.keys))
        for key in stable.keys {
            XCTAssertNotEqual(stable[key], alpha[key], "Shared namespace: \(key)")
            XCTAssertEqual(ReleaseTrain.alpha.value(key), alpha[key], "Generated catalogue drift: \(key)")
        }
        XCTAssertEqual(ReleaseTrain.alpha.deepLink("transcribe")?.scheme, "justspeaktoit-alpha")
        XCTAssertEqual(ReleaseTrain.alpha.cliExecutableName, "speak-alpha")
    }

    func testAlphaCannotReadStableLegacyKeychainServices() {
        let config = SecureStorageConfiguration(
            service: "vault", legacyServices: ["old-vault"], accessGroup: "TEAM.shared", releaseTrain: .alpha
        )
        XCTAssertEqual(config.service, "vault.alpha")
        XCTAssertEqual(config.legacyServices, ["old-vault.alpha"])
        XCTAssertEqual(config.accessGroup, "TEAM.shared.alpha")
    }

    func testTransportRejectsCrossTrainAndAlphaRejectsLegacyPeers() {
        XCTAssertTrue(ReleaseTrain.stable.acceptsPeer(nil))
        XCTAssertTrue(ReleaseTrain.alpha.acceptsPeer(.alpha))
        XCTAssertFalse(ReleaseTrain.alpha.acceptsPeer(nil))
        XCTAssertFalse(ReleaseTrain.alpha.acceptsPeer(.stable))
        XCTAssertFalse(ReleaseTrain.stable.acceptsPeer(.alpha))
    }

    func testAlphaExtensionInfersSafeTrainWhenMetadataMissing() {
        XCTAssertEqual(
            ReleaseTrain.resolve(metadata: nil, bundleIdentifier: "com.justspeaktoit.ios.alpha.keyboard"), .alpha
        )
        XCTAssertEqual(ReleaseTrain.resolve(metadata: nil, bundleIdentifier: "com.justspeaktoit.ios"), .stable)
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
