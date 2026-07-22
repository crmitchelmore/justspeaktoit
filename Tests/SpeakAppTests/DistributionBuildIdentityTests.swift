import Foundation
import XCTest

final class DistributionBuildIdentityTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMacDistributionChannels_useDistinctBundleIdentifiers() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains("\"com.justspeaktoit.mac.appstore\""))
        XCTAssertTrue(manifest.contains("\"com.justspeaktoit.mac\""))
        XCTAssertTrue(manifest.contains("bundleId: macBundleIdentifier"))
        XCTAssertTrue(manifest.contains("PRODUCT_BUNDLE_IDENTIFIER\": .string(macBundleIdentifier)"))
    }

    func testMacAppStoreWorkflow_exportsTheAppStoreIdentifier() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-appstore.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("BUNDLE_ID: com.justspeaktoit.mac.appstore"))
        XCTAssertTrue(workflow.contains("<key>com.justspeaktoit.mac.appstore</key>"))
        XCTAssertFalse(workflow.contains("<key>com.justspeaktoit.mac</key>"))
        XCTAssertTrue(workflow.contains("APPLE_TEAM_ID.$BUNDLE_ID"))
        XCTAssertTrue(workflow.contains("com.apple.application-identifier"))
        XCTAssertTrue(workflow.contains("com.apple.developer.icloud-container-identifiers"))
        XCTAssertTrue(workflow.contains("iCloud.com.justspeaktoit"))
        XCTAssertTrue(workflow.contains("$0 == \"iCloud.com.justspeaktoit\""))
        XCTAssertFalse(workflow.contains("grep -Fq \"iCloud.com.justspeaktoit\""))
        XCTAssertFalse(workflow.contains("Entitlements.application-identifier"))
    }

    func testDirectMacRelease_runsKeychainTestsBeforeInstallingSigningKeychain() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )

        let testStep = try XCTUnwrap(workflow.range(of: "- name: Run Tests (Release Config)"))
        let signingStep = try XCTUnwrap(workflow.range(of: "- name: Import Code Signing Certificate"))

        XCTAssertLessThan(testStep.lowerBound, signingStep.lowerBound)
    }

    func testDirectMacRelease_retriesDelayedDMGNotarizationTickets() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("for ATTEMPT in {1..5}"))
        XCTAssertTrue(workflow.contains("xcrun stapler staple \"$DMG_PATH\""))
        XCTAssertTrue(workflow.contains("xcrun stapler validate \"$DMG_PATH\""))
        XCTAssertTrue(workflow.contains("Notarization ticket not available yet; retrying in 15s"))
    }

    func testPlatformAppTargets_doNotCompileTheOtherPlatformsUI() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let macTarget = try targetBlock(named: "SpeakApp", in: manifest)
        let iosTarget = try targetBlock(named: "SpeakiOS", in: manifest)

        XCTAssertTrue(macTarget.contains("sources: [\"Sources/SpeakApp/**\"]"))
        XCTAssertFalse(macTarget.contains("SpeakiOSApp"))
        XCTAssertFalse(macTarget.contains("SpeakiOSLib"))
        XCTAssertFalse(macTarget.contains("JustSpeakToItWidgetExtension"))

        XCTAssertTrue(iosTarget.contains("sources: [\"SpeakiOSApp/**\"]"))
        XCTAssertTrue(iosTarget.contains(".package(product: \"SpeakiOSLib\")"))
        XCTAssertFalse(iosTarget.contains("Sources/SpeakApp"))
        XCTAssertFalse(iosTarget.contains("SpeakHotKeys"))
        XCTAssertFalse(iosTarget.contains("Sparkle"))
    }

    private func targetBlock(named name: String, in manifest: String) throws -> Substring {
        let marker = ".target(\n            name: \"\(name)\""
        let start = try XCTUnwrap(manifest.range(of: marker)?.lowerBound)
        let remainder = manifest[start...]
        let nextTarget = remainder.dropFirst(marker.count).range(of: "\n        .target(")?.lowerBound
        let end = nextTarget ?? manifest.endIndex
        return manifest[start..<end]
    }
}
