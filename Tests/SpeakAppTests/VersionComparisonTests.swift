import XCTest

/// Tests for version string comparison logic.
///
/// NOTE: These tests verify semantic version comparison logic conceptually.
/// Sparkle uses `SUStandardVersionComparator` internally which follows similar
/// semver rules. These tests document expected behavior and catch regressions
/// in our understanding of version ordering. They are reference tests, not
/// integration tests against Sparkle's actual comparator.
final class VersionComparisonTests: XCTestCase {

  /// Compare two semantic version strings using standard semver rules.
  /// Returns negative if v1 < v2, positive if v1 > v2, zero if equal.
  /// This mirrors the logic Sparkle uses for version comparison.
  private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
    let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

    // Pad to same length
    let maxLen = max(lhsParts.count, rhsParts.count)
    var lhsPadded = lhsParts + Array(repeating: 0, count: maxLen - lhsParts.count)
    var rhsPadded = rhsParts + Array(repeating: 0, count: maxLen - rhsParts.count)

    for index in 0..<maxLen {
      if lhsPadded[index] < rhsPadded[index] { return -1 }
      if lhsPadded[index] > rhsPadded[index] { return 1 }
    }
    return 0
  }

  /// Test: When appcast version is newer, should report update available.
  func testNewerVersionAvailable() {
    // Running 0.4.0, appcast has 0.5.0
    let hostVersion = "0.4.0"
    let appcastVersion = "0.5.0"

    let result = compareVersions(hostVersion, appcastVersion)
    XCTAssertLessThan(result, 0, "0.4.0 should be less than 0.5.0 - update available")
  }

  /// Test: When running same version as appcast, should be up to date.
  func testSameVersionUpToDate() {
    let hostVersion = "0.5.0"
    let appcastVersion = "0.5.0"

    let result = compareVersions(hostVersion, appcastVersion)
    XCTAssertEqual(result, 0, "Same versions should be equal - up to date")
  }

  /// Test: When running newer than appcast, should be up to date.
  func testRunningNewerVersion() {
    let hostVersion = "0.6.0"
    let appcastVersion = "0.5.0"

    let result = compareVersions(hostVersion, appcastVersion)
    XCTAssertGreaterThan(result, 0, "0.6.0 should be greater than 0.5.0")
  }

  /// Test: Patch version comparison.
  func testPatchVersionComparison() {
    XCTAssertLessThan(compareVersions("0.4.1", "0.4.2"), 0, "0.4.1 < 0.4.2")
    XCTAssertGreaterThan(compareVersions("0.4.10", "0.4.9"), 0, "0.4.10 > 0.4.9")
  }

  /// Test: Minor version comparison.
  func testMinorVersionComparison() {
    XCTAssertLessThan(compareVersions("0.4.0", "0.10.0"), 0, "0.4.0 < 0.10.0")
    XCTAssertGreaterThan(compareVersions("1.0.0", "0.99.99"), 0, "1.0.0 > 0.99.99")
  }

  /// Test: Short version strings are handled.
  func testShortVersionStrings() {
    XCTAssertEqual(compareVersions("1", "1.0"), 0, "1 == 1.0")
    XCTAssertEqual(compareVersions("1.0", "1.0.0"), 0, "1.0 == 1.0.0")
    XCTAssertLessThan(compareVersions("1", "1.0.1"), 0, "1 < 1.0.1")
  }

  /// Test: The actual issue - 0.3.0 vs 0.5.0 should indicate update needed.
  func testRealWorldScenario() {
    // User running 0.3.0, appcast shows 0.5.0 available
    let hostVersion = "0.3.0"
    let appcastVersion = "0.5.0"

    let updateAvailable = compareVersions(hostVersion, appcastVersion) < 0
    XCTAssertTrue(updateAvailable, "Running 0.3.0 with 0.5.0 available should offer update")
  }
}
