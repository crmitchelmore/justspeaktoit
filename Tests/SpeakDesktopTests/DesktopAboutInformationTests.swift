import Foundation
@testable import SpeakCore
import XCTest

final class DesktopAboutInformationTests: XCTestCase {
    func testAbout_UnstampedBuildIsNotPresentedAsLatestOrStable() {
        let information = DesktopAboutInformation(configuration: "debug")
        for platform in [DesktopAboutInformation.Platform.windows, .linux] {
            let details = information.details(for: platform)
            XCTAssertTrue(details.contains("Unversioned developer preview"))
            XCTAssertTrue(details.contains("Not stamped"))
            XCTAssertTrue(details.contains("no automatic updater"))
            XCTAssertTrue(details.contains("supports " + platform.rawValue))
            XCTAssertFalse(details.contains("up to date"))
            XCTAssertFalse(details.contains("Stable"))
        }
        let invalid = DesktopAboutInformation(version: "1.2\nforged", commit: "main", configuration: "debug")
        XCTAssertNil(invalid.version)
        XCTAssertNil(invalid.commit)
        XCTAssertNotNil(invalid.metadataNotice)
    }

    func testAbout_ReadsBothPackagedMetadataShapesWithoutUsingMacReleaseVersions() throws {
        let commit = String(repeating: "a", count: 40)
        let valid: [[String: Any]] = [
            ["sourceCommit": commit, "configuration": "release", "executables": ["SpeakWindows.exe": "hash"]],
            ["application": ["sourceCommit": commit, "configuration": "release"], "schemaVersion": 1]
        ]
        for object in valid {
            let metadata = try DesktopAboutInformation.decodeMetadata(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(metadata.commit, commit)
            XCTAssertEqual(metadata.configuration, "release")
        }
        let invalid: [[String: Any]] = [
            ["sourceCommit": "main"], ["sourceCommit": commit, "configuration": "Stable"],
            ["sourceCommit": commit + "\n"], ["application": ["sourceCommit": 42]]
        ]
        for object in invalid {
            XCTAssertThrowsError(
                try DesktopAboutInformation.decodeMetadata(JSONSerialization.data(withJSONObject: object))
            )
        }
        // swiftlint:disable:next line_length
        XCTAssertThrowsError(try DesktopAboutInformation.decodeMetadata(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)))
    }

    func testAbout_InstalledMetadataAndCorruptionAreVisibleWithoutReadingCheckoutVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("SpeakWindows.exe")
        let file = root.appendingPathComponent("app-build-metadata.json")
        let commit = String(repeating: "b", count: 40)
        try JSONSerialization.data(withJSONObject: ["sourceCommit": commit, "configuration": "release"]).write(to: file)
        let information = DesktopAboutInformation.current(
            executableURL: executable,
            bundleInformation: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "123"]
        )
        XCTAssertEqual(information.version, "1.2.3")
        XCTAssertEqual(information.build, "123")
        XCTAssertEqual(information.commit, commit)
        XCTAssertEqual(information.configuration, "Release")
        XCTAssertNil(information.metadataNotice)
        try Data("invalid".utf8).write(to: file)
        let corrupted = DesktopAboutInformation.current(executableURL: executable, bundleInformation: [:])
        XCTAssertNotNil(corrupted.metadataNotice)
        XCTAssertNil(corrupted.commit)
        XCTAssertTrue(corrupted.details(for: .windows).contains("Re-extract"))
    }

    func testAbout_LinksAreUniqueCanonicalHTTPSDestinations() {
        XCTAssertEqual(AppInformationLink.allCases.count, 6)
        XCTAssertEqual(Set(AppInformationLink.allCases.map(\.url)).count, 6)
        XCTAssertEqual(AppInformationLink.privacy.url, PrivacyPolicy.url)
        for link in AppInformationLink.allCases {
            XCTAssertFalse(link.title.isEmpty)
            XCTAssertEqual(link.url.scheme, "https")
            XCTAssertTrue(["github.com", "justspeaktoit.com"].contains(link.url.host ?? ""))
        }
        XCTAssertEqual(AppInformationLink.releases.url.path, "/crmitchelmore/justspeaktoit/releases")
        XCTAssertFalse(AppInformationLink.releases.url.absoluteString.contains("/latest"))
    }

    func testAbout_MetadataReadAcceptsExactLimitAndStopsAfterOneOverflowByte() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let maximum = 4 * 1024 * 1024
        let commit = String(repeating: "c", count: 40)
        let json = try JSONSerialization.data(withJSONObject: ["sourceCommit": commit])
        for overflow in [0, 32] {
            let file = root.appendingPathComponent("metadata-\(overflow).json")
            var padded = json
            padded.append(Data(repeating: 32, count: maximum - json.count + overflow))
            try padded.write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            if overflow == 0 {
                let data = try DesktopAboutInformation.readMetadata(handle)
                XCTAssertEqual(data.count, maximum)
                XCTAssertEqual(try DesktopAboutInformation.decodeMetadata(data).commit, commit)
                XCTAssertEqual(try handle.offset(), UInt64(maximum))
            } else {
                XCTAssertThrowsError(try DesktopAboutInformation.readMetadata(handle)) { error in
                    XCTAssertEqual((error as NSError).code, CocoaError.fileReadTooLarge.rawValue)
                }
                XCTAssertEqual(try handle.offset(), UInt64(maximum + 1))
            }
        }
    }
}
