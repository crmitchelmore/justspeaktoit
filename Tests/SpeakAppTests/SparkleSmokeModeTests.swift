import XCTest

@testable import SpeakApp

/// Launch-argument parsing for the headless Sparkle smoke mode
/// (`scripts/sparkle-update-smoke.sh`).
///
/// Getting this wrong in either direction is expensive: a false positive turns
/// a user's launch into a silent headless updater, and a false negative leaves
/// the release smoke job waiting six minutes for a result file that never
/// appears.
final class SparkleSmokeLaunchArgumentTests: XCTestCase {

    func testParse_isNotRequested_forAnOrdinaryLaunch() {
        XCTAssertEqual(
            SparkleSmokeArguments.parse(["/Applications/JustSpeakToIt.app/Contents/MacOS/JustSpeakToIt"]),
            .notRequested
        )
    }

    func testParse_isNotRequested_whenOnlyTheOtherFlagsArePresent() {
        // The feed override must never take effect without the mode flag.
        XCTAssertEqual(
            SparkleSmokeArguments.parse(["app", "--sparkle-feed-url", "http://127.0.0.1:8080/appcast.xml"]),
            .notRequested
        )
    }

    func testParse_acceptsSpaceSeparatedFlags() {
        let result = SparkleSmokeArguments.parse([
            "/tmp/JustSpeakToIt.app/Contents/MacOS/JustSpeakToIt",
            "--sparkle-smoke-update",
            "--sparkle-feed-url", "http://127.0.0.1:53421/appcast.xml",
            "--sparkle-result-file", "/tmp/smoke/result.json"
        ])
        XCTAssertEqual(
            result,
            .requested(
                SparkleSmokeArguments(
                    feedURLString: "http://127.0.0.1:53421/appcast.xml",
                    resultFilePath: "/tmp/smoke/result.json"
                )
            )
        )
    }

    func testParse_acceptsEqualsSeparatedFlags() {
        let result = SparkleSmokeArguments.parse([
            "app",
            "--sparkle-smoke-update",
            "--sparkle-feed-url=https://example.test/appcast.xml",
            "--sparkle-result-file=/tmp/result.json"
        ])
        XCTAssertEqual(
            result,
            .requested(
                SparkleSmokeArguments(
                    feedURLString: "https://example.test/appcast.xml",
                    resultFilePath: "/tmp/result.json"
                )
            )
        )
    }

    func testParse_rejectsAMissingFeedURL() {
        guard case .invalid(let reason) = SparkleSmokeArguments.parse([
            "app", "--sparkle-smoke-update", "--sparkle-result-file", "/tmp/result.json"
        ]) else {
            return XCTFail("A smoke run without a feed URL must not be accepted")
        }
        XCTAssertTrue(reason.contains("--sparkle-feed-url"), reason)
    }

    func testParse_rejectsAMissingResultFile() {
        guard case .invalid(let reason) = SparkleSmokeArguments.parse([
            "app", "--sparkle-smoke-update", "--sparkle-feed-url", "http://127.0.0.1:1/a.xml"
        ]) else {
            return XCTFail("A smoke run with nowhere to report must not be accepted")
        }
        XCTAssertTrue(reason.contains("--sparkle-result-file"), reason)
    }

    func testParse_rejectsAValueSwallowedByTheNextFlag() {
        guard case .invalid = SparkleSmokeArguments.parse([
            "app", "--sparkle-smoke-update", "--sparkle-feed-url", "--sparkle-result-file", "/tmp/r.json"
        ]) else {
            return XCTFail("An empty --sparkle-feed-url must be rejected, not read as the next flag")
        }
    }

    func testParse_rejectsANonHTTPFeed() {
        // The script serves the synthetic appcast over loopback HTTP; a file://
        // or custom-scheme feed is a mistake, not a supported mode.
        guard case .invalid(let reason) = SparkleSmokeArguments.parse([
            "app",
            "--sparkle-smoke-update",
            "--sparkle-feed-url", "file:///tmp/appcast.xml",
            "--sparkle-result-file", "/tmp/result.json"
        ]) else {
            return XCTFail("Only http and https feeds are supported")
        }
        XCTAssertTrue(reason.contains("http"), reason)
    }

    // MARK: - Verdict encoding

    func testOutcomeJSON_matchesWhatTheScriptAssertsOn() throws {
        XCTAssertEqual(
            SparkleSmokeOutcome.installing(fromVersion: "202609021530").jsonObject["result"] as? String,
            "installing"
        )
        XCTAssertEqual(
            SparkleSmokeOutcome.installing(fromVersion: "202609021530").jsonObject["from"] as? String,
            "202609021530"
        )
        XCTAssertEqual(
            SparkleSmokeOutcome.notFound(message: "up to date").jsonObject["result"] as? String,
            "not_found"
        )
        let error = SparkleSmokeOutcome.error(domain: "SUSparkleErrorDomain", code: 2001, message: "boom")
        XCTAssertEqual(error.jsonObject["result"] as? String, "error")
        XCTAssertEqual(error.jsonObject["domain"] as? String, "SUSparkleErrorDomain")
        XCTAssertEqual(error.jsonObject["code"] as? Int, 2001)
        XCTAssertEqual(error.jsonObject["message"] as? String, "boom")
    }

    func testOutcomeExitCodes_keepTheProcessAliveOnlyWhileInstalling() {
        // Sparkle terminates and relaunches the app itself; exiting here would
        // abort the very thing the smoke test is measuring.
        XCTAssertNil(SparkleSmokeOutcome.installing(fromVersion: "1").exitCode)
        XCTAssertEqual(SparkleSmokeOutcome.notFound(message: "").exitCode, 3)
        XCTAssertEqual(SparkleSmokeOutcome.error(domain: "d", code: 1, message: "").exitCode, 2)
    }

    func testResultWriter_writesReadableJSON() throws {
        let path = NSTemporaryDirectory() + "sparkle-smoke-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        SparkleSmokeResultWriter(path: path).write(.installing(fromVersion: "202609021530"))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(parsed["result"] as? String, "installing")
        XCTAssertEqual(parsed["from"] as? String, "202609021530")
    }
}

/// Info.plist keys the release smoke job depends on.
final class SparkleSmokeInfoPlistTests: XCTestCase {

    private func directChannelPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Config/AppInfo.plist"))
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    func testDirectBuildAdvertisesSmokeSupport() throws {
        // scripts/sparkle-update-smoke.sh reads this marker to tell a build that
        // understands --sparkle-smoke-update from an older release, which it
        // skips instead of failing.
        let value = try directChannelPlist()[SparkleSmokeMode.supportedInfoPlistKey]
        XCTAssertEqual(value as? Int, 1)
    }

    func testAppStoreBuildDoesNotAdvertiseSmokeSupport() throws {
        // App Store builds do not embed Sparkle and never self-update.
        let data = try Data(contentsOf: URL(fileURLWithPath: "Config/AppInfo.AppStore.plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNil(plist[SparkleSmokeMode.supportedInfoPlistKey])
    }

    func testAppTransportSecurityRelaxesLoopbackOnly() throws {
        // The smoke run serves its synthetic appcast over http://127.0.0.1.
        // NSAllowsLocalNetworking is the narrow exemption for that;
        // NSAllowsArbitraryLoads would open the whole internet to plain HTTP.
        let ats = try XCTUnwrap(directChannelPlist()["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
    }
}
