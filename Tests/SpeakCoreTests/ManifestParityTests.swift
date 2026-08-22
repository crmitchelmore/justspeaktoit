import Foundation
import XCTest

/// The root `Package.swift` and Tuist's `Project.swift` declare the same
/// remote packages. Xcode resolves both graphs together, so a requirement that
/// differs between them fails dependency resolution for every Tuist target —
/// which is how Dependabot's argmax-oss-swift 1.1.0 bump broke the iOS legs
/// while `swift build` passed (issue #757).
final class ManifestParityTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpeakCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func contents(of relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// `from:` requirement declared for `url` in Package.swift.
    private func packageRequirement(in manifest: String, url: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: url)
        let pattern = #"\.package\(\s*url:\s*"\#(escaped)"\s*,\s*(from|exact):\s*"([^"]+)""#
        return firstMatch(pattern, in: manifest)
    }

    /// `.upToNextMajor(from:)` / `.exact(...)` requirement declared for `url` in Project.swift.
    private func projectRequirement(in manifest: String, url: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: url)
        let requirement = #"\.(upToNextMajor\(from|exact\()\s*:?\s*"([^"]+)""#
        let pattern = #"\.remote\(\s*url:\s*"\#(escaped)"\s*,\s*requirement:\s*"# + requirement
        return firstMatch(pattern, in: manifest)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return String(text[range])
    }

    func testRemotePackageRequirements_matchBetweenPackageSwiftAndProjectSwift() throws {
        let package = try contents(of: "Package.swift")
        let project = try contents(of: "Project.swift")
        let shared = [
            "https://github.com/getsentry/sentry-cocoa.git",
            "https://github.com/argmaxinc/argmax-oss-swift.git",
            "https://github.com/FluidInference/FluidAudio.git"
        ]
        for url in shared {
            let packageVersion = try XCTUnwrap(
                packageRequirement(in: package, url: url), "\(url) missing from Package.swift"
            )
            let projectVersion = try XCTUnwrap(
                projectRequirement(in: project, url: url), "\(url) missing from Project.swift"
            )
            XCTAssertEqual(packageVersion, projectVersion, "\(url): Package.swift and Project.swift disagree")
        }
    }

    func testArgmaxPin_matchesTheBenchmarkRuntimeVersion() throws {
        let resolved = try contents(of: "Package.resolved")
        let runners = try contents(of: "Sources/LocalTranscriptionBenchmark/EngineRunners.swift")
        let pinnedVersion = try XCTUnwrap(
            firstMatch(
                #""identity" : "argmax-oss-swift".*?"(version)" : "([^"]+)""#,
                in: resolved
            ),
            "argmax-oss-swift pin missing from Package.resolved"
        )
        XCTAssertTrue(
            runners.contains("\"argmax-oss-swift \(pinnedVersion)\""),
            "EngineRunners.runtimeVersion must name the pinned argmax-oss-swift version \(pinnedVersion)"
        )
    }
}
