import Foundation
import XCTest

final class BenchmarkManifestParityTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LocalTranscriptionBenchmarkTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // LocalTranscription package root
    }

    private func contents(of relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return String(text[range])
    }

    func testArgmaxPin_matchesTheBenchmarkRuntimeVersion() throws {
        let resolved = try contents(of: "Package.resolved")
        let runners = try contents(of: "Sources/LocalTranscriptionBenchmark/EngineRunners.swift")
        let pinnedVersion = try XCTUnwrap(
            firstMatch(
                #""identity" : "argmax-oss-swift".*?"(version)" : "([^"]+)""#,
                in: resolved
            ),
            "argmax-oss-swift pin missing from benchmark Package.resolved"
        )
        XCTAssertTrue(
            runners.contains("\"argmax-oss-swift \(pinnedVersion)\""),
            "EngineRunners.runtimeVersion must name the benchmark's argmax-oss-swift pin \(pinnedVersion)"
        )
    }
}
