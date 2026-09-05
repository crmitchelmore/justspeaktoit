import Foundation
@testable import SpeakCore
import XCTest

final class ProductAnalyticsConsentConcurrencyTests: XCTestCase {
    func testOptInFinishesAfterWithdrawal_DoesNotRestoreConsentOrIdentity() async throws {
        let entered = expectation(description: "Opt-in is reopening")
        let gate = SuspensionGate(entered: entered)
        let fixture = try Fixture()
        await fixture.sink.pauseNextReopen(at: gate)
        let optingIn = Task { try await fixture.controller.setConsent(.optedIn) }
        await fulfillment(of: [entered], timeout: 2)

        try await fixture.controller.setConsent(.optedOut)
        await gate.release()
        try await optingIn.value
        try await fixture.controller.capture(.appActiveDaily)

        let consent = await fixture.controller.consentState()
        let payloads = await fixture.sink.payloads
        XCTAssertEqual(consent, .optedOut)
        XCTAssertEqual(try fixture.store.loadConsent(), .optedOut)
        XCTAssertNil(try fixture.store.loadInstallationID())
        XCTAssertTrue(payloads.isEmpty)
    }

    func testOptInDuringWithdrawal_WaitsForCleanupBeforeReopening() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        let oldIdentity = try XCTUnwrap(fixture.store.loadInstallationID())
        let entered = expectation(description: "Withdrawal is purging")
        let gate = SuspensionGate(entered: entered)
        await fixture.sink.pauseNextPurge(at: gate)
        let optingOut = Task { try await fixture.controller.setConsent(.optedOut) }
        await fulfillment(of: [entered], timeout: 2)

        let reopenedEarly = expectation(description: "Opt-in cannot finish during withdrawal")
        reopenedEarly.isInverted = true
        let cleanupIsPaused = LockedFlag()
        cleanupIsPaused.value = true
        let optingIn = Task {
            try await fixture.controller.setConsent(.optedIn)
            if cleanupIsPaused.value { reopenedEarly.fulfill() }
        }
        await fulfillment(of: [reopenedEarly], timeout: 0.05)
        XCTAssertEqual(try fixture.store.loadConsent(), .optedOut)
        cleanupIsPaused.value = false
        await gate.release()
        try await optingOut.value
        try await optingIn.value
        try await fixture.controller.capture(.appActiveDaily)

        let consent = await fixture.controller.consentState()
        let isOpen = await fixture.sink.isOpen
        let payloads = await fixture.sink.payloads
        XCTAssertEqual(consent, .optedIn)
        XCTAssertEqual(try fixture.store.loadConsent(), .optedIn)
        XCTAssertNotEqual(try fixture.store.loadInstallationID(), oldIdentity)
        XCTAssertTrue(isOpen)
        XCTAssertEqual(payloads.count, 1)
    }

    func testCaptureResumesAfterWithdrawal_DoesNotRecreateIdentityOrCapture() async throws {
        let fixture = try Fixture()
        try await fixture.prepareClosedConsentedSink()
        let entered = expectation(description: "Capture is reopening")
        let gate = SuspensionGate(entered: entered)
        await fixture.sink.pauseNextReopen(at: gate)
        let capture = Task { try await fixture.controller.capture(.appActiveDaily) }
        await fulfillment(of: [entered], timeout: 2)

        try await fixture.controller.setConsent(.optedOut)
        await gate.release()
        try await capture.value

        XCTAssertNil(try fixture.store.loadInstallationID())
        let payloads = await fixture.sink.payloads
        let consent = await fixture.controller.consentState()
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(consent, .optedOut)
    }

    func testKillSwitchChangesWhileReopening_RechecksBeforeIdentityAndCapture() async throws {
        let fixture = try Fixture()
        try await fixture.prepareClosedConsentedSink()
        let entered = expectation(description: "Capture is reopening")
        let gate = SuspensionGate(entered: entered)
        await fixture.sink.pauseNextReopen(at: gate)
        let capture = Task { try await fixture.controller.capture(.appActiveDaily) }
        await fulfillment(of: [entered], timeout: 2)

        fixture.killSwitch.value = true
        await gate.release()
        try await capture.value

        let payloads = await fixture.sink.payloads
        let isOpen = await fixture.sink.isOpen
        XCTAssertNil(try fixture.store.loadInstallationID())
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertFalse(isOpen)
    }

    func testRestoredConsent_ReopensSinkBeforeFirstCapture() async throws {
        let fixture = try Fixture(initialConsent: .optedIn)

        try await fixture.controller.capture(.appActiveDaily)

        let payloads = await fixture.sink.payloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertNotNil(try fixture.store.loadInstallationID())
    }
}

private extension ProductAnalyticsConsentConcurrencyTests {
    struct Fixture {
        let sink = SuspendedSink()
        let store: FileProductAnalyticsStateStore
        let controller: ProductAnalyticsController
        let killSwitch = LockedFlag()

        init(initialConsent: AnalyticsConsentState = .unknown) throws {
            let stateURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("analytics.json")
            store = FileProductAnalyticsStateStore(fileURL: stateURL)
            try store.saveConsent(initialConsent)
            let flag = killSwitch
            controller = try ProductAnalyticsController(
                context: ProductAnalyticsContext(
                    platform: .macOS, appVersion: "1.0", build: "1", osMajorMinor: "26.0",
                    distributionChannel: .development, localeLanguageCode: "en", architecture: "arm64"
                ),
                sink: sink,
                stateStore: store,
                forceDisabled: { flag.value }
            )
        }

        func prepareClosedConsentedSink() async throws {
            try await controller.setConsent(.optedIn)
            try await controller.capture(.appActiveDaily)
            killSwitch.value = true
            try await controller.capture(.appActiveDaily)
            killSwitch.value = false
        }
    }

    actor SuspensionGate {
        private let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init(entered: XCTestExpectation) { self.entered = entered }

        func pause() async {
            guard !released else { return }
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    actor SuspendedSink: ProductAnalyticsSink {
        var isOpen = false
        var payloads: [ProductAnalyticsPayload] = []
        private var reopenGate: SuspensionGate?
        private var purgeGate: SuspensionGate?

        func pauseNextReopen(at gate: SuspensionGate) { reopenGate = gate }
        func pauseNextPurge(at gate: SuspensionGate) { purgeGate = gate }

        func reopen() async throws {
            isOpen = true
            if let gate = reopenGate {
                reopenGate = nil
                await gate.pause()
            }
        }

        func capture(_ payload: ProductAnalyticsPayload) async throws {
            if isOpen { payloads.append(payload) }
        }

        func purge() async throws {
            isOpen = false
            payloads.removeAll()
            if let gate = purgeGate {
                purgeGate = nil
                await gate.pause()
            }
        }

        func close() async { isOpen = false }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = false

        var value: Bool {
            get { lock.withLock { storedValue } }
            set { lock.withLock { storedValue = newValue } }
        }
    }
}
