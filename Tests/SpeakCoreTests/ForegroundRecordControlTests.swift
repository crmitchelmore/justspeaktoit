import SpeakCore
import XCTest

final class ForegroundRecordControlTests: XCTestCase {
    func testIdleControl_isVisiblyNamedTranscribe() {
        let control = ForegroundRecordControl(phase: .idle, handsFreeArmed: false, handsFreeEnabled: false)
        XCTAssertEqual(control.title, "Transcribe")
        XCTAssertEqual(control.symbolName, "mic.fill")
        XCTAssertEqual(control.accessibilityLabel, "Start recording")
        XCTAssertEqual(control.inputLabels, ["Transcribe", "Start recording"])
    }

    func testEveryStateHasAVisibleTitleAndAMatchingVoiceControlLabel() {
        let phases: [ForegroundRecordControl.Phase] = [.idle, .starting, .recording, .stopping]
        for phase in phases {
            for armed in [false, true] {
                for enabled in [false, true] {
                    let control = ForegroundRecordControl(
                        phase: phase, handsFreeArmed: armed, handsFreeEnabled: enabled
                    )
                    XCTAssertFalse(control.title.isEmpty, "\(phase) armed=\(armed) enabled=\(enabled)")
                    XCTAssertEqual(control.inputLabels.first, control.title)
                    XCTAssertTrue(control.inputLabels.contains(control.accessibilityLabel))
                }
            }
        }
    }

    func testRecordingStatesOverrideHandsFree() {
        let recording = ForegroundRecordControl(phase: .recording, handsFreeArmed: true, handsFreeEnabled: true)
        XCTAssertEqual(recording.title, "Stop")
        XCTAssertEqual(recording.accessibilityLabel, "Stop recording")
        let starting = ForegroundRecordControl(phase: .starting, handsFreeArmed: true, handsFreeEnabled: true)
        XCTAssertEqual(starting.accessibilityLabel, "Cancel starting recording")
        let armed = ForegroundRecordControl(phase: .idle, handsFreeArmed: true, handsFreeEnabled: true)
        XCTAssertEqual(armed.accessibilityLabel, "Disarm hands-free dictation")
        let enabled = ForegroundRecordControl(phase: .idle, handsFreeArmed: false, handsFreeEnabled: true)
        XCTAssertEqual(enabled.accessibilityLabel, "Arm hands-free dictation")
        XCTAssertEqual(enabled.title, "Transcribe")
    }
}
