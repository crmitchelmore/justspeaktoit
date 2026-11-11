import Foundation
import XCTest
@testable import SpeakCore

/// The keyboard hand-off start policy (issue #1469): which audio categories a
/// start may try, and what the keyboard is told when a start fails.
final class KeyboardHandoffStartDiagnosisTests: XCTestCase {
    private typealias Diagnosis = KeyboardHandoffStartDiagnosis

    private static func osStatus(_ fourCC: String) -> NSError {
        let code = fourCC.utf8.reduce(0) { ($0 << 8) | Int($1) }
        return NSError(domain: "NSOSStatusErrorDomain", code: code)
    }

    func testSessionCategories_backgroundStartNeverTriesNonMixable() {
        XCTAssertEqual(Diagnosis.sessionCategories(applicationIsInForeground: false), [.mixable])
    }

    func testSessionCategories_foregroundPrefersIsolatedThenMixable() {
        XCTAssertEqual(Diagnosis.sessionCategories(applicationIsInForeground: true), [.isolated, .mixable])
    }

    func testBackgroundRefusal_recognisesEachRefusalCode() {
        for code in ["!rec", "!pri", "!int"] {
            XCTAssertTrue(Diagnosis.isBackgroundAudioRefusal(Self.osStatus(code)), code)
        }
        XCTAssertEqual(Self.osStatus("!rec").code, 561_145_187)
    }

    func testBackgroundRefusal_ignoresOtherErrors() {
        XCTAssertFalse(Diagnosis.isBackgroundAudioRefusal(Self.osStatus("msrv")))
        XCTAssertFalse(Diagnosis.isBackgroundAudioRefusal(NSError(domain: "x", code: -50)))
        XCTAssertFalse(Diagnosis.isBackgroundAudioRefusal(CancellationError()))
    }

    func testBackgroundRefusal_findsWrappedUnderlyingError() {
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: Self.osStatus("!rec")])
        XCTAssertTrue(Diagnosis.isBackgroundAudioRefusal(wrapped))
    }

    func testFailureCode_backgroundRefusalAsksUserToOpenApp() {
        XCTAssertEqual(
            Diagnosis.failureCode(stage: .recording, error: Self.osStatus("!rec"), applicationIsInForeground: false),
            .appUnavailable
        )
    }

    func testFailureCode_foregroundRefusalStaysRecordingUnavailable() {
        XCTAssertEqual(
            Diagnosis.failureCode(stage: .recording, error: Self.osStatus("!rec"), applicationIsInForeground: true),
            .recordingUnavailable
        )
    }

    func testFailureCode_otherRecordingErrorIsRecordingUnavailable() {
        XCTAssertEqual(
            Diagnosis.failureCode(stage: .recording, error: Self.osStatus("msrv"), applicationIsInForeground: false),
            .recordingUnavailable
        )
        XCTAssertEqual(
            Diagnosis.failureCode(stage: .recording, applicationIsInForeground: false),
            .recordingUnavailable
        )
    }

    func testFailureCode_missingCredentialsOrProfileIsProfileUnavailable() {
        for stage in [Diagnosis.Stage.credentials, .profile] {
            for foreground in [true, false] {
                XCTAssertEqual(
                    Diagnosis.failureCode(
                        stage: stage, error: Self.osStatus("!rec"), applicationIsInForeground: foreground
                    ),
                    .profileUnavailable,
                    "\(stage) foreground=\(foreground)"
                )
            }
        }
    }

    func testFailureCode_busyIsRecordingUnavailable() {
        XCTAssertEqual(Diagnosis.failureCode(stage: .busy, applicationIsInForeground: false), .recordingUnavailable)
    }

    func testDiagnosticSummary_namesStageStateAndDecodedCode() {
        let summary = Diagnosis.diagnosticSummary(
            stage: .recording, error: Self.osStatus("!rec"), applicationIsInForeground: false
        )
        XCTAssertTrue(summary.contains("stage=recording"), summary)
        XCTAssertTrue(summary.contains("appForeground=false"), summary)
        XCTAssertTrue(summary.contains("failure=appUnavailable"), summary)
        XCTAssertTrue(summary.contains("fourCC='!rec'"), summary)
        XCTAssertTrue(summary.contains("backgroundRefusal=true"), summary)
    }

    func testDiagnosticSummary_withoutErrorOmitsErrorFields() {
        let summary = Diagnosis.diagnosticSummary(stage: .busy, error: nil, applicationIsInForeground: true)
        XCTAssertEqual(summary, "stage=busy appForeground=true failure=recordingUnavailable")
    }
}
