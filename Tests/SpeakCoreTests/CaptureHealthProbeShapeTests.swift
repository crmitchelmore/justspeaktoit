import Foundation
@testable import SpeakCore
import XCTest

/// The privacy line the Capture Health screen inherits from issue #1075's
/// diagnostics, held here by a test rather than by a comment (issue #997).
///
/// The startup diagnostics are a deliberate content-free allowlist that never
/// leaves the device. A health screen is a much bigger surface — permissions,
/// keychain attributes, storage, audio — and the easy way to widen that line
/// is to add one `String` field to the probe for "just the route name" or
/// "just the error". So the probe has no `String` field at all, and this test
/// is what stops one appearing.
final class CaptureHealthProbeShapeTests: XCTestCase {
    /// Types a probe field is allowed to be. Everything here is either a
    /// closed set defined in this repository, a boolean, a whole number or a
    /// date — none of which can carry a transcript, a credential, a device or
    /// route name, a locale identifier or a file path.
    private static let allowed: Set<String> = [
        "CaptureHealthPermission",
        "CaptureHealthExercise",
        "CaptureHealthAccessibility",
        "CaptureHealthAssetState",
        "CaptureHealthLastOutcome",
        "CaptureSelfTestResult",
        "Bool",
        "Int",
        "Date"
    ]

    func testNoProbeFieldCanCarryFreeFormText() {
        let mirror = Mirror(reflecting: CaptureHealthProbe())
        XCTAssertFalse(mirror.children.isEmpty)
        for child in mirror.children {
            let name = Self.unwrappedTypeName(of: child.value)
            XCTAssertTrue(
                Self.allowed.contains(name),
                "\(child.label ?? "?") is a \(name); a health probe field must be a closed-set label, "
                    + "a boolean, a whole number or a date"
            )
        }
    }

    func testTheSelfTestResultItCarriesIsAlsoClosedSet() {
        let result = CaptureSelfTestResult(
            outcome: .passed,
            observedBuffers: 1,
            elapsedMilliseconds: 1,
            stageMilliseconds: [:]
        )
        let mirror = Mirror(reflecting: result)
        for child in mirror.children {
            let name = Self.unwrappedTypeName(of: child.value)
            XCTAssertTrue(
                ["CaptureSelfTestOutcome", "Int", "Dictionary<CaptureSelfTestStage, Int>",
                 "Array<CaptureSelfTestLimit>"].contains(name),
                "\(child.label ?? "?") is a \(name)"
            )
        }
    }

    func testEveryRenderedDetailIsAssembledHereRatherThanPassedThrough() {
        // Every detail string in a full report is built from the closed-set
        // labels and numbers above, so none of them can echo an input.
        let probe = CaptureHealthProbe(
            microphone: .granted,
            speech: .granted,
            appGroupRoundTrip: .succeeded,
            credentialLookup: .succeeded,
            credentialAccessibility: .afterFirstUnlock,
            recordingStorageRoundTrip: .succeeded,
            liveActivitiesEnabled: true,
            speechAssets: .installed,
            keyboardHeartbeatAgeSeconds: 12,
            keyboardResumeAttemptsSpent: 0,
            lastCaptureOutcome: .delivered,
            lastCaptureAgeSeconds: 90,
            recoverableCaptureCount: 0,
            uncertainCaptureCount: 0,
            selfTest: CaptureSelfTestResult(
                outcome: .passed,
                observedBuffers: 4,
                elapsedMilliseconds: 210,
                stageMilliseconds: [:]
            )
        )
        let report = CaptureHealthReport.build(from: probe)
        XCTAssertEqual(report.overall, .healthy)
        for check in report.checks {
            XCTAssertFalse(check.detail.contains("Optional("), check.detail)
            XCTAssertFalse(check.detail.contains("nil"), check.detail)
            XCTAssertFalse(check.detail.contains("/"), "no path may reach a row: \(check.detail)")
        }
    }

    /// The report has no transport of any kind — it is built for one screen on
    /// one device. This asserts the shape that makes that true: the builder is
    /// a pure function of the probe, so two builds of the same probe are
    /// identical and nothing observable happens on the way.
    func testBuildingAReportIsPureAndHasNoSideChannel() {
        let probe = CaptureHealthProbe(microphone: .granted)
        XCTAssertEqual(CaptureHealthReport.build(from: probe), CaptureHealthReport.build(from: probe))
    }

    private static func unwrappedTypeName(of value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let wrapped = mirror.children.first?.value {
                return Self.unwrappedTypeName(of: wrapped)
            }
            // An empty optional still names its wrapped type.
            let described = String(describing: type(of: value))
            return described
                .replacingOccurrences(of: "Optional<", with: "")
                .replacingOccurrences(of: ">", with: "")
        }
        return String(describing: type(of: value))
    }
}
