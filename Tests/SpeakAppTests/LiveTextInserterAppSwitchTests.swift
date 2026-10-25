import ApplicationServices
import Foundation
import XCTest

@testable import SpeakApp

final class LiveTextInserterAppSwitchTests: XCTestCase {
    @MainActor
    func testAppSwitchBeforeFirstWrite_routesBothInsertionStrategiesThroughFinalPolicy() {
        for strategy in [LiveTextInserter.InsertionStrategy.fullValue, .rangedStreaming] {
            for policy in [AppSettings.AppSwitchDelivery.currentApp, .onlyIfOriginalAppInFront] {
                let field = FakeStreamingTextField()
                let inserter = LiveTextInserterTestFactory.make(field: field, policy: policy, strategy: strategy)
                observeFocus(on: inserter, policy: policy, originalInFront: { false })
                inserter.update(with: "hello")
                let result = inserter.applyPolishedFinal("Hello.")
                switch (policy, result) {
                case (.currentApp, .redirected), (.onlyIfOriginalAppInFront, .clipboard): break
                default: XCTFail("An app switch must route final delivery before any live write")
                }
                XCTAssertEqual(field.value, "")
            }
        }
    }

    @MainActor
    private func makeInserter(
        field: FakeStreamingTextField, policy: AppSettings.AppSwitchDelivery = .originalApp
    ) -> LiveTextInserter {
        LiveTextInserterTestFactory.make(field: field, policy: policy)
    }

    @MainActor
    private func observeFocus(
        on inserter: LiveTextInserter, policy: AppSettings.AppSwitchDelivery, originalInFront: @escaping () -> Bool
    ) {
        inserter.appSwitchDecisionProvider = { _ in
            SmartTextOutput.appSwitchDecision(
                policy: policy, capturedApplicationIsFrontmost: originalInFront(),
                capturedApplicationIsRunning: true,
                frontmostProcessIdentifier: originalInFront() ? 123 : 456, ownProcessIdentifier: 999
            )
        }
        inserter.redirectedTargetProvider = {
            TextOutputTarget(processIdentifier: 456, applicationName: "New app", bundleIdentifier: nil,
                             applicationLaunchDate: nil, focusedElement: nil)
        }
    }

    @MainActor
    func testStrictAppSwitch_stopsLiveWritesAndKeepsFinalOnClipboard() {
        let field = FakeStreamingTextField()
        let inserter = makeInserter(field: field, policy: .onlyIfOriginalAppInFront)
        var originalInFront = true
        observeFocus(on: inserter, policy: .onlyIfOriginalAppInFront, originalInFront: { originalInFront })
        inserter.update(with: "hello")
        originalInFront = false
        inserter.update(with: "hello there")
        XCTAssertEqual(field.value, "hello")
        guard case .clipboard(.originalApplicationNotInFront) = inserter.applyPolishedFinal("Hello there.") else {
            return XCTFail("Strict delivery must preserve the final on the clipboard")
        }
        XCTAssertEqual(field.value, "hello")
    }

    @MainActor
    func testCurrentAppSwitch_pinsTheFinalDestinationWithoutRewritingTheOriginal() {
        let field = FakeStreamingTextField()
        let inserter = makeInserter(field: field, policy: .currentApp)
        var originalInFront = true
        observeFocus(on: inserter, policy: .currentApp, originalInFront: { originalInFront })
        inserter.update(with: "hello")
        originalInFront = false
        inserter.update(with: "hello there")
        guard case .redirected(let destination) = inserter.applyPolishedFinal("Hello there.") else {
            return XCTFail("Final delivery must follow the current-app policy")
        }
        XCTAssertEqual(destination.processIdentifier, 456)
        XCTAssertTrue(destination.requiresFrontmostAtDelivery)
        XCTAssertEqual(field.value, "hello")
        XCTAssertEqual(field.selectedTextWrites.count, 1)
    }

    @MainActor
    func testSwitchAwayAndBack_finalizesTheOwnedRegionWithoutPastingAnotherCopy() {
        for policy in [AppSettings.AppSwitchDelivery.currentApp, .onlyIfOriginalAppInFront] {
            let field = FakeStreamingTextField(value: "Before ", selection: CFRange(location: 7, length: 0))
            let inserter = makeInserter(field: field, policy: policy)
            var originalInFront = true
            observeFocus(on: inserter, policy: policy, originalInFront: { originalInFront })
            inserter.update(with: "hello")
            originalInFront = false
            inserter.update(with: "hello there")
            originalInFront = true
            guard case .applied = inserter.applyPolishedFinal("Hello there.") else {
                return XCTFail("Return to the original must finalize its existing region")
            }
            XCTAssertEqual(field.value, "Before Hello there.")
            XCTAssertEqual(field.selectedTextWrites.count, 2)
            XCTAssertFalse(inserter.usingClipboardFallback)
        }
    }

    @MainActor
    func testAppSwitchAfterRangeSelection_refusesThePendingTextWrite() {
        let field = FakeStreamingTextField()
        let inserter = makeInserter(field: field, policy: .onlyIfOriginalAppInFront)
        var originalInFront = true
        observeFocus(on: inserter, policy: .onlyIfOriginalAppInFront, originalInFront: { originalInFront })
        field.onSelectionWrite = { originalInFront = false }
        inserter.update(with: "hello")
        XCTAssertTrue(field.selectedTextWrites.isEmpty)
        XCTAssertEqual(field.value, "")
        guard case .clipboard = inserter.applyPolishedFinal("Hello.") else {
            return XCTFail("Late app switch must not claim that final text was applied")
        }
    }

    @MainActor
    func testAppSwitchDuringFinalPatch_cannotReturnAppliedForTheUnwrittenFinal() {
        let field = FakeStreamingTextField()
        let inserter = makeInserter(field: field, policy: .onlyIfOriginalAppInFront)
        var originalInFront = true
        observeFocus(on: inserter, policy: .onlyIfOriginalAppInFront, originalInFront: { originalInFront })
        inserter.update(with: "hello")
        field.onSelectionWrite = { originalInFront = false }
        guard case .clipboard = inserter.applyPolishedFinal("Hello there.") else {
            return XCTFail("A blocked final patch must not report applied")
        }
        XCTAssertEqual(field.value, "hello")
        XCTAssertEqual(field.selectedTextWrites.count, 1)
    }

    @MainActor
    func testReturnDuringRedirectCapture_finalizesTheOriginalOwnedRegion() {
        let field = FakeStreamingTextField()
        let inserter = makeInserter(field: field, policy: .currentApp)
        var originalInFront = true
        observeFocus(on: inserter, policy: .currentApp, originalInFront: { originalInFront })
        inserter.update(with: "hello")
        originalInFront = false
        inserter.redirectedTargetProvider = {
            originalInFront = true
            return TextOutputTarget(processIdentifier: 123, applicationName: "Original app", bundleIdentifier: nil,
                                    applicationLaunchDate: nil, focusedElement: nil)
        }
        guard case .applied = inserter.applyPolishedFinal("Hello there.") else {
            return XCTFail("A return during target capture must preserve owned-region finalization")
        }
        XCTAssertEqual(field.value, "Hello there.")
        XCTAssertEqual(field.selectedTextWrites.count, 2)
    }

}
