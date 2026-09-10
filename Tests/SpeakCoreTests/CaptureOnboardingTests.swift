import XCTest

@testable import SpeakCore

final class CaptureOnboardingTests: XCTestCase {
    private let iPhone18 = CaptureHardwareProfile(
        hasActionButton: true,
        supportsNativeControls: true,
        supportsShortcutGestures: true,
        supportsKeyboardExtension: true
    )

    private let iPhoneOniOS17 = CaptureHardwareProfile(
        hasActionButton: false,
        supportsNativeControls: false,
        supportsShortcutGestures: true,
        supportsKeyboardExtension: true
    )

    private func fluentState() -> CaptureOnboardingState {
        CaptureOnboardingState(firstRunCompleted: true, successfulDictations: 3)
    }

    // MARK: - A transcript is the only evidence

    func testBlankTranscriptProvesNothing() {
        var state = CaptureOnboardingState(firstRunCompleted: true, successfulDictations: 2)
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .control, transcript: "   \n\t ")
        XCTAssertEqual(state.successfulDictations, 2)
        XCTAssertTrue(state.provenTriggers.isEmpty)
    }

    func testEmptyTranscriptProvesNothing() {
        var state = CaptureOnboardingState(firstRunCompleted: true, successfulDictations: 2)
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .shortcut, transcript: "")
        XCTAssertEqual(state.successfulDictations, 2)
        XCTAssertFalse(state.provenTriggers.contains(.shortcut))
    }

    func testRealTranscriptProvesExactlyItsOwnTrigger() {
        var state = CaptureOnboardingState(firstRunCompleted: true)
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .control, transcript: "hello there")
        XCTAssertEqual(state.successfulDictations, 1)
        XCTAssertEqual(state.provenTriggers, [.control])
        XCTAssertFalse(state.provenTriggers.contains(.shortcut))
        XCTAssertFalse(state.provenTriggers.contains(.keyboard))
    }

    // MARK: - Cards are earned, not given

    func testNoCardBeforeTheFirstRunSheetIsFinished() {
        let state = CaptureOnboardingState(firstRunCompleted: false, successfulDictations: 9)
        XCTAssertNil(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18))
    }

    func testNoCardBeforeThreeSuccessfulDictations() {
        for count in 0..<CaptureOnboardingPolicy.dictationsBeforeTriggerCards {
            let state = CaptureOnboardingState(firstRunCompleted: true, successfulDictations: count)
            XCTAssertNil(
                CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18),
                "offered a card after \(count) dictations"
            )
        }
    }

    func testControlCardIsOfferedOnceFluent() {
        XCTAssertEqual(
            CaptureOnboardingPolicy.offeredCard(state: self.fluentState(), hardware: self.iPhone18),
            .control
        )
    }

    func testThreeInAppDictationsEarnTheFirstCard() {
        var state = CaptureOnboardingPolicy.completingFirstRun(CaptureOnboardingState())
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .inApp, transcript: "one")
        XCTAssertNil(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18))
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .inApp, transcript: "two")
        XCTAssertNil(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18))
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .inApp, transcript: "three")
        XCTAssertEqual(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18), .control)
    }

    // MARK: - Only hardware the device really has

    func testControlCardIsNotOfferedWithoutNativeControlSupport() {
        XCTAssertEqual(
            CaptureOnboardingPolicy.offeredCard(state: self.fluentState(), hardware: self.iPhoneOniOS17),
            .shortcut
        )
    }

    func testKeyboardOnlyDeviceIsOnlyOfferedTheKeyboardCard() {
        let hardware = CaptureHardwareProfile(
            hasActionButton: false,
            supportsNativeControls: false,
            supportsShortcutGestures: false,
            supportsKeyboardExtension: true
        )
        XCTAssertEqual(CaptureOnboardingPolicy.offeredCard(state: self.fluentState(), hardware: hardware), .keyboard)
    }

    func testNoCardsAtAllWhenNothingIsSupported() {
        let hardware = CaptureHardwareProfile(
            hasActionButton: false,
            supportsNativeControls: false,
            supportsShortcutGestures: false,
            supportsKeyboardExtension: false
        )
        XCTAssertNil(CaptureOnboardingPolicy.offeredCard(state: self.fluentState(), hardware: hardware))
    }

    func testInAppIsNeverACard() {
        XCTAssertFalse(self.iPhone18.supports(.inApp))
        XCTAssertFalse(CaptureOnboardingPolicy.cardOrder.contains(.inApp))
    }

    // MARK: - Never nag

    func testDismissalSticks() {
        var state = self.fluentState()
        state = CaptureOnboardingPolicy.dismissingCard(state, trigger: .control)
        XCTAssertEqual(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18), .shortcut)
        state = CaptureOnboardingPolicy.dismissingCard(state, trigger: .shortcut)
        XCTAssertEqual(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18), .keyboard)
        state = CaptureOnboardingPolicy.dismissingCard(state, trigger: .keyboard)
        XCTAssertNil(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18))
    }

    func testDismissalSurvivesFurtherSuccessfulDictations() {
        var state = CaptureOnboardingPolicy.dismissingCard(self.fluentState(), trigger: .control)
        for _ in 0..<20 {
            state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .inApp, transcript: "more words")
        }
        XCTAssertNotEqual(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18), .control)
    }

    func testAProvenHandsFreeTriggerRetiresTheOtherHandsFreeCard() {
        var state = self.fluentState()
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .control, transcript: "it works")
        // The Control is proven, so the Shortcut card is pointless — but the
        // keyboard is a different capability and is still worth offering.
        XCTAssertEqual(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18), .keyboard)
    }

    func testAProvenShortcutRetiresTheControlCard() {
        var state = self.fluentState()
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .shortcut, transcript: "it works")
        XCTAssertEqual(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18), .keyboard)
    }

    func testEverythingProvenMeansSilence() {
        var state = self.fluentState()
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .control, transcript: "a")
        state = CaptureOnboardingPolicy.recordingDictation(state, trigger: .keyboard, transcript: "b")
        XCTAssertNil(CaptureOnboardingPolicy.offeredCard(state: state, hardware: self.iPhone18))
    }

    // MARK: - First run

    func testFirstRunIsPresentedOnlyUntilItIsCompleted() {
        let fresh = CaptureOnboardingState()
        XCTAssertTrue(CaptureOnboardingPolicy.shouldPresentFirstRun(state: fresh))
        let done = CaptureOnboardingPolicy.completingFirstRun(fresh)
        XCTAssertFalse(CaptureOnboardingPolicy.shouldPresentFirstRun(state: done))
    }

    func testSkippingTheTestDictationStillCompletesFirstRunButProvesNothing() {
        let state = CaptureOnboardingPolicy.completingFirstRun(CaptureOnboardingState())
        XCTAssertTrue(state.firstRunCompleted)
        XCTAssertEqual(state.successfulDictations, 0)
        XCTAssertTrue(state.provenTriggers.isEmpty)
    }

    func testTheTestDictationGateOnlyOpensForRealText() {
        XCTAssertFalse(CaptureOnboardingPolicy.isProvenTranscript(""))
        XCTAssertFalse(CaptureOnboardingPolicy.isProvenTranscript(" \n "))
        XCTAssertTrue(CaptureOnboardingPolicy.isProvenTranscript("testing one two three"))
    }

    func testTestDictationLimitIsTwentySeconds() {
        XCTAssertEqual(CaptureOnboardingPolicy.testDictationLimit, 20)
    }

    // MARK: - Action Button hardware table

    func testActionButtonModels() {
        XCTAssertTrue(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPhone16,1"))
        XCTAssertTrue(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPhone16,2"))
        XCTAssertTrue(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPhone17,3"))
        XCTAssertTrue(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPhone18,1"))
    }

    func testNonActionButtonModels() {
        XCTAssertFalse(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPhone15,4"))
        XCTAssertFalse(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPhone16,3"))
        XCTAssertFalse(ActionButtonHardware.hasActionButton(deviceIdentifier: "iPad14,3"))
        XCTAssertFalse(ActionButtonHardware.hasActionButton(deviceIdentifier: "arm64"))
        XCTAssertFalse(ActionButtonHardware.hasActionButton(deviceIdentifier: ""))
    }

    func testIsIPhone() {
        XCTAssertTrue(ActionButtonHardware.isIPhone(deviceIdentifier: "iPhone12,1"))
        XCTAssertFalse(ActionButtonHardware.isIPhone(deviceIdentifier: "iPad14,3"))
        XCTAssertFalse(ActionButtonHardware.isIPhone(deviceIdentifier: "iPhoneX"))
    }

    // MARK: - Store

    @MainActor
    func testStorePersistsAndRefusesUnearnedProgress() {
        let suiteName = "CaptureOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CaptureOnboardingStore(defaults: defaults)
        XCTAssertTrue(store.shouldPresentFirstRun)
        store.completeFirstRun()
        store.recordDictation(trigger: .inApp, transcript: "one")
        store.recordDictation(trigger: .inApp, transcript: "two")
        store.recordDictation(trigger: .control, transcript: "   ")
        store.recordDictation(trigger: .inApp, transcript: "three")

        XCTAssertEqual(store.state.successfulDictations, 3)
        XCTAssertEqual(store.state.provenTriggers, [.inApp])
        XCTAssertEqual(store.offeredCard(hardware: self.iPhone18), .control)

        let reloaded = CaptureOnboardingStore(defaults: defaults)
        XCTAssertFalse(reloaded.shouldPresentFirstRun)
        XCTAssertEqual(reloaded.state, store.state)
        reloaded.dismissCard(.control)
        XCTAssertEqual(CaptureOnboardingStore(defaults: defaults).offeredCard(hardware: self.iPhone18), .shortcut)
    }
}
