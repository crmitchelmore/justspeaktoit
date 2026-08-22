import Foundation
import XCTest

@testable import SpeakAutomationKit

/// `speak --version` must describe a standalone binary from the version linked
/// into it, fall back to the enclosing app bundle for the embedded CLI, and
/// never invent a version (issue #775).
final class SpeakCLIVersionTests: XCTestCase {
    func testEmbeddedVersion_winsWhenPresent() {
        let version = SpeakCLIVersion.resolve(
            embeddedVersion: { Data("2.62.0\n\u{0}\u{0}".utf8) },
            mainBundleVersion: { "9.9.9" },
            executableURL: URL(fileURLWithPath: "/Applications/JustSpeakToIt.app/Contents/MacOS/speak"),
            bundleLoader: { _ in nil }
        )
        XCTAssertEqual(version, "2.62.0")
    }

    func testWithoutEmbeddedVersion_fallsBackToTheDevelopmentVersion() {
        // A bare executable under Application Support: no linked version, no
        // bundle of its own, no enclosing app. Nothing can vouch for a version.
        let version = SpeakCLIVersion.resolve(
            embeddedVersion: { nil },
            mainBundleVersion: { nil },
            executableURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/SpeakApp/bin/speak"),
            bundleLoader: { _ in nil }
        )
        XCTAssertEqual(version, "0.0.0-dev")
    }

    func testWithoutEmbeddedVersion_usesTheEnclosingAppBundle() throws {
        let bundle = try XCTUnwrap(Bundle(for: SpeakCLIVersionTests.self) as Bundle?)
        let version = SpeakCLIVersion.resolve(
            embeddedVersion: { nil },
            mainBundleVersion: { nil },
            executableURL: URL(fileURLWithPath: "/Applications/JustSpeakToIt.app/Contents/MacOS/speak"),
            bundleLoader: { url in url.lastPathComponent == "JustSpeakToIt.app" ? bundle : nil }
        )
        XCTAssertEqual(version, bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev")
    }

    func testEmbeddedSection_rejectsGarbage() {
        XCTAssertNil(SpeakCLIVersion.parseEmbeddedVersion(Data()))
        XCTAssertNil(SpeakCLIVersion.parseEmbeddedVersion(Data([0xFF, 0xFE, 0x00])))
        XCTAssertNil(SpeakCLIVersion.parseEmbeddedVersion(Data("   \n".utf8)))
        XCTAssertNil(SpeakCLIVersion.parseEmbeddedVersion(Data("2.62.0; rm -rf /".utf8)))
        XCTAssertEqual(
            SpeakCLIVersion.parseEmbeddedVersion(Data(" 2.62.0-beta.1+build7 ".utf8)),
            "2.62.0-beta.1+build7"
        )
    }

    func testSectionNames_matchTheReleaseBuildFlags() {
        XCTAssertEqual(SpeakCLIVersion.embeddedSectionSegment, "__TEXT")
        XCTAssertEqual(SpeakCLIVersion.embeddedSectionName, "__speak_ver")
    }

    func testDevelopmentBuild_hasNoEmbeddedSection() {
        // The test binary is not linked with -sectcreate, so the live reader must return nil, not crash.
        XCTAssertNil(SpeakCLIVersion.embeddedVersionData())
    }
}
