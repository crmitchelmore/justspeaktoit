import SpeakCore
import SpeakLinuxPlatform
import XCTest

final class LinuxOnboardingPageTests: XCTestCase {
    func testEveryCanonicalStepProjectsItsOrderMetadataAndImplementedActions() {
        for (index, step) in DesktopOnboardingStep.allCases.enumerated() {
            let page = LinuxOnboardingPage(step)
            XCTAssertEqual(page.step, step)
            XCTAssertEqual(page.index, Int32(index))
            XCTAssertEqual(page.title, step.title)
            XCTAssertEqual(page.progress, step.progress)
            XCTAssertEqual(page.hasPrevious, step.previous != nil)
            XCTAssertEqual(page.isLast, step.next == nil)
            XCTAssertEqual(page.actions, step.actions.filter { $0 != .testDictation })
            XCTAssertFalse(page.actions.contains(.testDictation))
            if step != .textInsertion { XCTAssertEqual(page.detail, step.detail) }
        }
    }

    func testInsertionGuidanceDescribesLinuxWithoutWindowsElevationAdvice() {
        let page = LinuxOnboardingPage(.textInsertion)
        XCTAssertTrue(page.detail.contains("X11"))
        XCTAssertTrue(page.detail.contains("Wayland"))
        XCTAssertTrue(page.detail.contains("manual paste"))
        XCTAssertTrue(page.detail.contains("No access is granted"))
        XCTAssertFalse(page.detail.contains("administrator"))
        XCTAssertNotEqual(page.detail, DesktopOnboardingStep.textInsertion.detail)
    }

    func testMicrophoneActionIsLabelledAsPassiveGuidanceWithoutChangingOtherTitles() {
        for step in DesktopOnboardingStep.allCases {
            let page = LinuxOnboardingPage(step)
            for action in page.actions {
                if action == .openMicrophoneSettings {
                    XCTAssertEqual(page.title(for: action), "Check microphone permissions...")
                } else {
                    XCTAssertEqual(page.title(for: action), action.title)
                }
            }
        }
        let practice = LinuxOnboardingPage(.hotkeyPractice)
        XCTAssertEqual(practice.actions, [.chooseShortcut])
        XCTAssertTrue(practice.detail.contains("shortcut"))
    }

    func testEveryGuideActionRoutesToItsImplementedDestination() {
        let expected: [(DesktopOnboardingAction, LinuxOnboardingPage.Destination?)] = [
            (.openPermissions, .permissions), (.openMicrophoneSettings, .permissions),
            (.chooseMicrophone, .general), (.chooseTextOutput, .general),
            (.chooseRemoteProvider, .apiKeys), (.downloadLocalModel, .transcription),
            (.chooseShortcut, .keyboard), (.openPostProcessing, .postProcessing), (.testDictation, nil)
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(DesktopOnboardingAction.allCases))
        for (action, destination) in expected {
            XCTAssertEqual(LinuxOnboardingPage.destination(for: action), destination, action.rawValue)
        }
    }
}
