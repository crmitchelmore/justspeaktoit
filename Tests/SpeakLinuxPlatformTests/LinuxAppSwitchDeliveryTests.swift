import Foundation
import SpeakCore
import SpeakDesktop
import SpeakLinuxPlatform
import XCTest

final class LinuxAppSwitchDeliveryTests: XCTestCase {
    private let x11 = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"])
    private let wayland = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w-0"])
    private let target = LinuxInsertionTarget(
        kind: .x11Window(42), windowClass: "gedit", executablePath: "/fixture/editor", processID: 123,
        processIdentity: "456"
    )

    func testOldInitializerReferenceAndAbsentKeyKeepWaylandPaste() throws {
        let old: (LinuxTextOutputOptions.Method, Bool) -> LinuxTextOutputOptions = LinuxTextOutputOptions.init
        let options = try JSONDecoder().decode(LinuxTextOutputOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, old(.paste, true))
        XCTAssertNil(options.appSwitchDelivery)
        XCTAssertEqual(LinuxOutputPlan.make(
            options: options, target: .init(kind: .focusedApplication), session: wayland, portalAvailable: true
        ), .portalPaste(shift: false))
    }

    func testEveryExplicitWaylandIntentIsRetainedAndCopiesWithoutPortal() throws {
        for policy in AppSwitchDelivery.allCases {
            let options = LinuxTextOutputOptions(appSwitchDelivery: policy)
            let decoded = try JSONDecoder().decode(LinuxTextOutputOptions.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded.appSwitchDelivery, policy)
            let native = PolicyNative()
            let plan = try XCTUnwrap(LinuxOutputPlan.make(
                options: decoded, target: .init(kind: .focusedApplication), session: wayland, portalAvailable: true
            ))
            let result = LinuxOutputJob(plan: plan, native: native).performResult("text")
            XCTAssertEqual(result.disposition, .recoveryCopy)
            XCTAssertEqual(native.clipboard, "text")
            XCTAssertEqual(native.pastes, 0)
            XCTAssertEqual(native.portals, 0)
            XCTAssertFalse(result.permitsAutomaticResume)
        }
    }

    func testSameForegroundPolicyPastesWithImmutableOriginalOptions() throws {
        var options = LinuxTextOutputOptions(appSwitchDelivery: .onlyIfOriginalAppInFront)
        options.restoreClipboard = false
        let plan = try XCTUnwrap(LinuxOutputPlan.make(
            options: options, target: target, session: x11, portalAvailable: false
        ))
        options.appSwitchDelivery = .currentApp
        options.method = .clipboardOnly
        XCTAssertEqual(plan, .guardedX11(target: target, policy: .onlyIfOriginalAppInFront, restoreClipboard: false))
        let native = PolicyNative()
        let result = LinuxOutputJob(plan: plan, native: native).performResult("text")
        XCTAssertEqual(native.targets, [target])
        XCTAssertEqual(native.pastes, 1)
        XCTAssertEqual(result.disposition, .unconfirmedInsertion)
        XCTAssertFalse(result.permitsAutomaticResume)
    }

    func testStaleOrSwitchedDestinationNeverUsesUnrelatedField() {
        for policy in AppSwitchDelivery.allCases {
            let native = PolicyNative()
            native.front = false
            let result = LinuxOutputJob(
                plan: .guardedX11(target: target, policy: policy, restoreClipboard: false), native: native
            ).performResult("text")
            XCTAssertEqual(result.disposition, .recoveryCopy)
            XCTAssertEqual(native.clipboard, "text")
            XCTAssertEqual(native.pastes, 0)
            XCTAssertEqual(native.portals, 0)
        }
    }

    func testOwnUIIsNotANewDestination() {
        let native = PolicyNative()
        native.own = true
        let result = LinuxOutputJob(
            plan: .guardedX11(target: target, policy: .currentApp, restoreClipboard: false), native: native
        ).performResult("text")
        XCTAssertEqual(result.disposition, .recoveryCopy)
        XCTAssertEqual(native.pastes, 0)
    }

    func testSecondFocusChangeBetweenAdmissionAndPasteCopiesInstead() {
        let native = PolicyNative()
        native.secondFocus = true
        let result = LinuxOutputJob(
            plan: .guardedX11(target: target, policy: .currentApp, restoreClipboard: false), native: native
        ).performResult("text")
        XCTAssertEqual(native.targets, [target])
        XCTAssertEqual(native.clipboard, "text")
        XCTAssertEqual(native.pastes, 0)
        XCTAssertEqual(result.disposition, .recoveryCopy)
    }

    func testCancelledPolicyDoesNotCopyOrPaste() {
        let native = PolicyNative()
        let job = LinuxOutputJob(
            plan: .guardedX11(target: target, policy: .originalApp, restoreClipboard: false), native: native
        )
        job.cancel()
        XCTAssertEqual(job.performResult("text").disposition, .cancelled)
        XCTAssertNil(native.clipboard)
        XCTAssertEqual(native.pastes, 0)
    }

    func testClipboardFailureIsNotSuccessfulDeliveryOrLearningEvidence() {
        let native = PolicyNative()
        native.front = false
        native.failCopy = true
        let result = LinuxOutputJob(
            plan: .guardedX11(target: target, policy: .currentApp, restoreClipboard: false), native: native
        ).performResult("text")
        XCTAssertEqual(result.disposition, .failed)
        XCTAssertFalse(result.permitsAutomaticResume)
        XCTAssertNil(native.clipboard)
        XCTAssertEqual(native.pastes, 0)
    }

    func testNativePayloadHasStrictIndicesAndPreservesLegacySelection() throws {
        for policy in AppSwitchDelivery.allCases {
            let options = try LinuxTextOutputOptions(
                nativeMethod: 0, payload: "restore\t\(AppSwitchDelivery.desktopSelection(policy))"
            )
            XCTAssertTrue(options.restoreClipboard)
            XCTAssertEqual(options.appSwitchDelivery, policy)
        }
        XCTAssertNil(try LinuxTextOutputOptions(nativeMethod: 1, payload: "\t0").appSwitchDelivery)
        for payload in ["restore", "restore\t-1", "\t04", "\t+1", "\t99", "bad\t1", "\t1\textra"] {
            XCTAssertThrowsError(try LinuxTextOutputOptions(nativeMethod: 0, payload: payload), payload)
        }
        XCTAssertThrowsError(try LinuxTextOutputOptions(nativeMethod: 2, payload: "\t0"))
    }
}

final class PolicyNative: LinuxOutputNative, @unchecked Sendable {
    var front = true, own = false, secondFocus = false, failCopy = false
    var clipboard: String?
    var pastes = 0, portals = 0
    var targets: [LinuxInsertionTarget] = []
    func x11TargetIsFront(_ target: LinuxInsertionTarget) throws -> Bool { front }
    func x11Paste(target: LinuxInsertionTarget, shift: Bool) throws -> Bool {
        targets.append(target)
        guard !secondFocus else { return false }
        pastes += 1
        return true
    }
    func readClipboard() throws -> String? { clipboard }
    func writeClipboard(_ text: String) throws {
        if failCopy { throw CocoaError(.fileWriteUnknown) }
        clipboard = text
    }
    func writeOwnedClipboard(_ text: String) throws -> UInt64 { try writeClipboard(text); return 1 }
    func restoreClipboard(_ text: String, ownership: UInt64) throws -> Bool { false }
    func x11Paste(window: UInt64, shift: Bool) throws -> Bool { pastes += 1; return true }
    func prepareRemoteDesktop() throws -> Bool { portals += 1; return true }
    func remotePaste(text: String?, shift: Bool) throws { portals += 1 }
    func ownWindowFocused() -> Bool { own }
    func notify(title: String, body: String) {}
    func sleep(milliseconds: Int) {}
}
