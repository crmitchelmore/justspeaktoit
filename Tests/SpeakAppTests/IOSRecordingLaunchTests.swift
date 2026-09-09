import Foundation
import XCTest

final class IOSRecordingLaunchTests: XCTestCase {
    func testAppProcessLaunch_resetsRecordingBeforeLaunchWorkAndOnlyOnce() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("SpeakiOSApp/SpeakiOSApp.swift"),
            encoding: .utf8
        )
        // Launching the real delegate in a unit test also registers notifications,
        // activates Watch connectivity and syncs CloudKit. Guard its wiring here;
        // SharedTranscriptionStateTests exercise the persisted-state behavior.
        let code = source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/|//[^\n]*"#,
            with: "",
            options: .regularExpression
        )
        let launchSignature = try XCTUnwrap(code.range(of: "didFinishLaunchingWithOptions"))
        let bodyStart = try XCTUnwrap(code.range(of: ") -> Bool {", range: launchSignature.upperBound..<code.endIndex))
        let launchBody = code[bodyStart.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let reset = "SharedTranscriptionState.shared.clearRecordingState()"

        XCTAssertTrue(
            launchBody.hasPrefix(reset),
            "Reconcile the previous process before notifications, Watch, CloudKit or quick actions can start work"
        )
        XCTAssertEqual(
            code.components(separatedBy: reset).count - 1,
            1,
            "Only process launch may reset recording; foreground entry must preserve a live session"
        )
    }
}
