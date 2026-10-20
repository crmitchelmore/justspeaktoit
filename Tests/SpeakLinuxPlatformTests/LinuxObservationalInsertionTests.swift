import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakLinuxPlatform
import XCTest

final class LinuxObservationalInsertionTests: XCTestCase {
    func testNativeContractFixtures_UseNoBusOrUI() {
        XCTAssertEqual(LinuxAtspiTarget.contractSelfTest(), 0)
    }

    func testPendingNativeControlPolicy_KeepsImmediateStopActionable() {
        XCTAssertEqual(LinuxAtspiTarget.pendingControlsContractSelfTest(), 0)
    }

    func testNativeInputUsesUnicodeCharactersAndUTF8Bytes_NotUTF16OrGraphemes() {
        let supplementary = String(repeating: "\u{1F600}", count: 8192)
        XCTAssertTrue(LinuxAtspiTarget.inputIsRepresentable(supplementary))
        XCTAssertEqual(supplementary.utf8.count, 32768)
        XCTAssertEqual(supplementary.utf16.count, 16384)
        XCTAssertFalse(LinuxAtspiTarget.inputIsRepresentable(supplementary + "a"))
        let combining = String(repeating: "e\u{301}", count: 4097)
        XCTAssertLessThan(combining.count, 8192)
        XCTAssertFalse(LinuxAtspiTarget.inputIsRepresentable(combining))
        XCTAssertFalse(LinuxAtspiTarget.inputIsRepresentable(""))
        XCTAssertFalse(LinuxAtspiTarget.inputIsRepresentable("a\0b"))
    }
    func testObservedSpan_IsDistinctFromAcknowledgmentAndDoesNotTouchClipboard() {
        let native = RecordingNative()
        let span = SyntheticObservationalInsertion(.observedSpan)
        let job = LinuxOutputJob(
            plan: .portalPaste(shift: false), native: native, options: .init(), observational: span
        )
        let result = job.performResult("Susie")
        XCTAssertEqual(result.disposition, .observedInsertion)
        XCTAssertFalse(result.permitsAutomaticResume)
        XCTAssertEqual(job.correctionReadback?.provenance, .observationalATSPISpan)
        XCTAssertTrue(native.log.isEmpty)
        XCTAssertTrue(result.status.contains("not acknowledged"))
    }

    func testIndeterminateDispatch_NeverFallsBackOrCreatesLearningLease() {
        let native = RecordingNative()
        let span = SyntheticObservationalInsertion(.indeterminateAfterDispatch)
        let job = LinuxOutputJob(
            plan: .x11Paste(window: 4, shift: false, restoreClipboard: true),
            native: native, options: .init(), observational: span
        )
        let result = job.performResult("Susie")
        XCTAssertEqual(result.disposition, .failed)
        XCTAssertFalse(result.permitsAutomaticResume)
        XCTAssertTrue(native.log.isEmpty)
        XCTAssertNil(job.correctionReadback)
        XCTAssertEqual(span.cancels, 1)
    }

    func testUnavailableBeforeMutation_PreservesUnconfirmedPasteWithoutLearning() {
        let native = RecordingNative()
        let span = SyntheticObservationalInsertion(.unavailableBeforeDispatch)
        let job = LinuxOutputJob(
            plan: .portalPaste(shift: false), native: native, options: .init(), observational: span
        )
        XCTAssertEqual(job.performResult("Susie").disposition, .unconfirmedInsertion)
        XCTAssertTrue(native.log.contains("portal-start"))
        XCTAssertNil(job.correctionReadback)
    }

    func testCancellationDuringObservedDelivery_RemovesLeaseWithoutFallback() {
        let native = RecordingNative()
        let span = SyntheticObservationalInsertion(.observedSpan)
        let job = LinuxOutputJob(
            plan: .portalPaste(shift: false), native: native, options: .init(), observational: span
        )
        span.onInsert = { job.cancel() }
        XCTAssertEqual(job.performResult("Susie").disposition, .cancelled)
        XCTAssertNil(job.correctionReadback)
        XCTAssertTrue(native.log.isEmpty)
    }

    func testOrdinaryPasteAndClipboardNeverBecomeObservationalReceipts() {
        let native = RecordingNative()
        let paste = LinuxOutputJob(plan: .portalPaste(shift: false), native: native)
        XCTAssertEqual(paste.performResult("Susie").disposition, .unconfirmedInsertion)
        XCTAssertNil(paste.correctionReadback)
        let copy = LinuxOutputJob(plan: .copy(reason: nil), native: native)
        XCTAssertEqual(copy.performResult("Susie").disposition, .copied)
        XCTAssertNil(copy.correctionReadback)
    }

    func testExplicitAppSwitchPolicies_NeverReuseOriginalObservation() throws {
        let x11 = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"])
        let wayland = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w-0"])
        for policy in AppSwitchDelivery.allCases {
            for (isWayland, front) in [(false, false), (false, true), (true, true)] {
                var options = LinuxTextOutputOptions(appSwitchDelivery: policy)
                options.restoreClipboard = false
                let target = LinuxInsertionTarget(
                    kind: isWayland ? .focusedApplication : .x11Window(4),
                    windowClass: nil, executablePath: nil, processID: 42, processIdentity: "123"
                )
                let native = PolicyNative()
                native.front = front
                let span = SyntheticObservationalInsertion(.observedSpan)
                let plan = try XCTUnwrap(LinuxOutputPlan.make(
                    options: options, target: target, session: isWayland ? wayland : x11, portalAvailable: true
                ))
                let job = LinuxOutputJob(plan: plan, native: native, options: options, observational: span)
                let result = job.performResult("Susie")
                XCTAssertEqual(result.disposition, !isWayland && front ? .unconfirmedInsertion : .recoveryCopy)
                XCTAssertEqual(span.inserts, 0)
                XCTAssertNil(job.correctionReadback)
                XCTAssertFalse(result.permitsAutomaticResume)
                XCTAssertEqual(native.clipboard, "Susie")
                XCTAssertEqual(native.pastes, !isWayland && front ? 1 : 0)
                XCTAssertEqual(native.targets, !isWayland && front ? [target] : [])
                XCTAssertEqual(native.portals, 0)
                job.cancel()
                XCTAssertEqual(span.cancels, 0)
            }
        }
    }

    func testLegacyWayland_ObservesOriginalFieldEvenWithoutPortalBeforeCopyFallback() throws {
        let session = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w-0"])
        let options = LinuxTextOutputOptions()
        for portalAvailable in [false, true] {
            let native = PolicyNative()
            let span = SyntheticObservationalInsertion(.observedSpan)
            let plan = try XCTUnwrap(LinuxOutputPlan.make(
                options: options, target: .init(kind: .focusedApplication),
                session: session, portalAvailable: portalAvailable
            ))
            XCTAssertEqual(plan.isClipboard, !portalAvailable)
            let job = LinuxOutputJob(plan: plan, native: native, options: options, observational: span)
            XCTAssertFalse(job.isClipboard)
            let result = job.performResult("Susie")
            XCTAssertEqual(result.disposition, .observedInsertion)
            XCTAssertEqual(span.inserts, 1)
            XCTAssertEqual(job.correctionReadback?.provenance, .observationalATSPISpan)
            XCTAssertFalse(result.permitsAutomaticResume)
            XCTAssertNil(native.clipboard)
            XCTAssertEqual(native.pastes, 0)
            XCTAssertEqual(native.portals, 0)
        }
    }

    func testClipboardOnly_NeverAcquiresOrCancelsOriginalObservation() throws {
        let session = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "w-0"])
        let policies: [AppSwitchDelivery?] = [nil] + AppSwitchDelivery.allCases.map { Optional($0) }
        for policy in policies {
            var options = LinuxTextOutputOptions(method: .clipboardOnly)
            options.appSwitchDelivery = policy
            let native = PolicyNative()
            let span = SyntheticObservationalInsertion(.observedSpan)
            let plan = try XCTUnwrap(LinuxOutputPlan.make(
                options: options, target: nil, session: session, portalAvailable: true
            ))
            let job = LinuxOutputJob(plan: plan, native: native, options: options, observational: span)
            XCTAssertTrue(job.isClipboard)
            let result = job.performResult("Susie")
            XCTAssertEqual(result.disposition, .copied)
            XCTAssertEqual(span.inserts, 0)
            XCTAssertNil(job.correctionReadback)
            XCTAssertTrue(result.permitsAutomaticResume)
            XCTAssertEqual(native.clipboard, "Susie")
            XCTAssertEqual(native.pastes, 0)
            XCTAssertEqual(native.portals, 0)
            job.cancel()
            XCTAssertEqual(span.cancels, 0)
        }
    }

    func testLegacyX11_UnavailableObservationKeepsUnconfirmedOriginalPaste() throws {
        let session = LinuxDesktopSession(environment: ["XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"])
        let options = LinuxTextOutputOptions()
        let plan = try XCTUnwrap(LinuxOutputPlan.make(
            options: options, target: .init(kind: .x11Window(4)), session: session, portalAvailable: false
        ))
        let native = RecordingNative()
        let span = SyntheticObservationalInsertion(.unavailableBeforeDispatch)
        let job = LinuxOutputJob(plan: plan, native: native, options: options, observational: span)
        let result = job.performResult("Susie")
        XCTAssertEqual(result.disposition, .unconfirmedInsertion)
        XCTAssertEqual(span.inserts, 1)
        XCTAssertTrue(native.log.contains("x11:4:false"))
        XCTAssertNil(job.correctionReadback)
        XCTAssertFalse(result.permitsAutomaticResume)
    }

    func testOriginalInitializerFunctionReferences_RemainAvailableWithoutObservation() {
        let original: (LinuxInsertionTarget.Kind, String?, String?) -> LinuxInsertionTarget =
            LinuxInsertionTarget.init(kind:windowClass:executablePath:)
        let guarded: (LinuxInsertionTarget.Kind, String?, String?, Int32, String?) -> LinuxInsertionTarget =
            LinuxInsertionTarget.init(kind:windowClass:executablePath:processID:processIdentity:)
        let makeJob: (LinuxOutputPlan, any LinuxOutputNative) -> LinuxOutputJob = LinuxOutputJob.init(plan:native:)
        XCTAssertNil(original(.focusedApplication, nil, nil).observationalTarget)
        let target = guarded(.x11Window(4), nil, nil, 42, "123")
        XCTAssertEqual(target.processID, 42)
        XCTAssertEqual(target.processIdentity, "123")
        XCTAssertNil(target.observationalTarget)
        let job = makeJob(.copy(reason: nil), RecordingNative())
        XCTAssertTrue(job.isClipboard)
        XCTAssertNil(job.correctionReadback)
        XCTAssertEqual(job.performResult("Susie").disposition, .copied)
    }
}

private final class SyntheticObservationalInsertion: LinuxObservationalInsertion, @unchecked Sendable {
    let application: String? = "Synthetic"
    let provenance = DesktopCorrectionProvenance.observationalATSPISpan
    private let result: LinuxObservationalDelivery
    private let lock = NSLock()
    private var cancelCount = 0
    private var insertionCount = 0
    var onInsert: (@Sendable () -> Void)?
    var cancels: Int { lock.withLock { cancelCount } }
    var inserts: Int { lock.withLock { insertionCount } }
    init(_ result: LinuxObservationalDelivery) { self.result = result }
    func insert(_ text: String) -> LinuxObservationalDelivery {
        lock.withLock { insertionCount += 1 }
        onInsert?()
        return result
    }
    func begin(original: String) throws {}
    func read() throws -> String { "Susy" }
    func cancel() { lock.withLock { cancelCount += 1 } }
}
