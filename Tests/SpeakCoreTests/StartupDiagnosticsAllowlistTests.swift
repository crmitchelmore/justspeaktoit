import XCTest
@testable import SpeakCore

/// The emitted startup lines must carry nothing but the allowlisted,
/// content-free fields (issue #972): no transcript, prompt, audio, credential,
/// raw error, device or route name, and no persistent identifier.
final class StartupDiagnosticsAllowlistTests: XCTestCase {
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = Date(timeIntervalSince1970: 1_000)
        private var emitted: [String] = []

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return instant
        }

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return emitted
        }

        func advance(milliseconds: Int) {
            lock.lock(); defer { lock.unlock() }
            instant = instant.addingTimeInterval(Double(milliseconds) / 1000)
        }

        func makeDiagnostics() -> StartupDiagnostics {
            StartupDiagnostics(
                now: { [self] in now },
                emit: { [self] line in
                    lock.lock(); defer { lock.unlock() }
                    emitted.append(line)
                }
            )
        }
    }

    private static let allowedKeys: Set<String> = [
        "run", "origin", "entry", "backend", "outcome",
        "credentials-ms", "audio-session-ms", "engine-start-ms",
        "session-start-ms", "first-partial-ms"
    ]

    private static let closedSets: [String: Set<String>] = [
        "origin": Set(StartupEntryOrigin.allCases.map(\.rawValue)),
        "entry": ["upstream", "local"],
        "backend": Set(StartupBackend.allCases.map(\.rawValue)).union(["unresolved"]),
        "outcome": Set(StartupOutcome.allCases.map(\.rawValue))
    ]

    func testEmittedLinesCarryOnlyTheAllowlistedFields() {
        let harness = Harness()
        var diagnostics = harness.makeDiagnostics()
        let run = UUID()
        diagnostics.begin(
            run: run,
            entry: StartupEntry(origin: .keyboardHandoff, observedAt: harness.now),
            localOrigin: .service
        )
        for stage in StartupStage.allCases where stage != .firstPartial {
            harness.advance(milliseconds: 5)
            diagnostics.note(.stage(stage), run: run)
        }
        diagnostics.note(.backend(.sharedClient), run: run)
        diagnostics.finish(.started, run: run)
        harness.advance(milliseconds: 5)
        diagnostics.noteFirstPartial(run: run)

        XCTAssertEqual(harness.lines.count, 2)
        for line in harness.lines { assertOnlyAllowlistedFields(in: line) }
    }

    private func assertOnlyAllowlistedFields(in line: String) {
        let tokens = line.split(separator: " ")
        XCTAssertTrue(["startup", "startup-partial"].contains(String(tokens[0])), line)
        for token in tokens.dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1)
            XCTAssertEqual(parts.count, 2, "unstructured token in \(line)")
            let key = String(parts[0])
            let value = String(parts[1])
            XCTAssertTrue(Self.allowedKeys.contains(key), "unexpected field \(key) in \(line)")
            if let allowed = Self.closedSets[key] {
                XCTAssertTrue(allowed.contains(value), "unexpected \(key)=\(value)")
            } else if key == "run" {
                // An ephemeral per-run correlation token, not an identity.
                XCTAssertEqual(value.count, 8)
                XCTAssertTrue(value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            } else {
                XCTAssertNotNil(Int(value), "\(key) must be a whole number of ms")
            }
        }
    }

    /// The run token is derived from an identifier created for this start and
    /// discarded with it — two runs never share one, and it is stable for
    /// neither a device nor a user.
    func testRunTokenIsPerRunAndNotAPersistentIdentifier() {
        let first = StartupTimeline(run: UUID(), origin: .service, entryAt: Date(), entryIsUpstream: false)
        let second = StartupTimeline(run: UUID(), origin: .service, entryAt: Date(), entryIsUpstream: false)
        XCTAssertNotEqual(first.runToken, second.runToken)
    }
}
