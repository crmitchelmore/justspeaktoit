import Foundation
import SpeakCore

/// Runtime packaging checks use the production executable and its actual
/// SwiftPM resource accessor. They need no microphone, account or network.
enum WindowsBundleSelfTest {
    private struct Fixture: Codable, Equatable {
        let text: String
        let values: [Int]
    }

    static func run() async throws {
        guard !ReleaseNotesCatalog.bundled.entries.isEmpty else {
            throw WindowsNativeError(message: "Bundle resource lookup failed: bundled release notes are empty.")
        }
        let fixture = Fixture(text: "Hello, κόσμε 👋", values: [-1, 0, 42])
        let encoded = try JSONEncoder().encode(fixture)
        guard try JSONDecoder().decode(Fixture.self, from: encoded) == fixture else {
            throw WindowsNativeError(message: "Bundle Codable round trip failed.")
        }
        let expression = try NSRegularExpression(pattern: #"(?<=Hello, )\p{L}+"#)
        let match = expression.firstMatch(
            in: fixture.text, range: NSRange(fixture.text.startIndex..., in: fixture.text)
        )
        guard let match, let range = Range(match.range, in: fixture.text), fixture.text[range] == "κόσμε" else {
            throw WindowsNativeError(message: "Bundle Unicode regular expression failed.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy MMMM dd"
        guard formatter.string(from: Date(timeIntervalSince1970: 0)) == "1970 January 01",
              "i".uppercased(with: Locale(identifier: "tr_TR")) == "İ" else {
            throw WindowsNativeError(message: "Bundle ICU locale or date formatting failed.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bundle proof κόσμε " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Unicode 👋.json")
        try encoded.write(to: file, options: .atomic)
        guard try Data(contentsOf: file) == encoded else {
            throw WindowsNativeError(message: "Bundle atomic file round trip failed.")
        }
        // Optional handshake keeps this short test alive until the external
        // isolation harness has sampled the loaded DLL paths. No fixed delay
        // is imposed on ordinary launches or manually run self-tests.
        if let releasePath = ProcessInfo.processInfo.environment["JSTI_BUNDLE_PROBE_RELEASE_PATH"] {
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: releasePath) {
                guard Date() < deadline else {
                    throw WindowsNativeError(message: "Bundle module probe did not acknowledge within 10 seconds.")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        print("JSTI_BUNDLE_SELF_TEST_OK: resources, Codable, Unicode regex, ICU and atomic file I/O")
    }
}
