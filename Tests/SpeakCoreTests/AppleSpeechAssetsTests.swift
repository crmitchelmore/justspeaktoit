import XCTest
@testable import SpeakCore

@MainActor
final class AppleSpeechAssetsTests: XCTestCase {
    @MainActor
    private final class Inventory {
        var states: [AppleSpeechAssetStatus]
        var queries = 0
        var installs = 0
        var sleeps = 0
        var preparing = 0
        var failFirstInstall = false
        var installCompletes = false

        init(_ states: [AppleSpeechAssetStatus]) { self.states = states }

        func recordSleep() { sleeps += 1 }
        func recordPreparing() { preparing += 1 }

        func status() -> AppleSpeechAssetStatus {
            queries += 1
            return states.count > 1 ? states.removeFirst() : states[0]
        }

        func install() throws -> Bool {
            installs += 1
            if failFirstInstall && installs == 1 { throw URLError(.notConnectedToInternet) }
            if installCompletes { states = [.installed] }
            return true
        }
    }

    func testInstalledOnly_allStatesNeverInstallOrPoll() async {
        for state in [AppleSpeechAssetStatus.supported, .downloading, .unsupported, .installed] {
            let inventory = Inventory([state])
            do {
                try await AppleSpeechAssets.ensure(
                    policy: .installedOnly,
                    status: { await inventory.status() },
                    install: { try await inventory.install() },
                    sleep: { _ in await inventory.recordSleep() },
                    onPreparing: { XCTFail("Live startup must not prepare assets") }
                )
                XCTAssertEqual(state, .installed)
            } catch {
                guard case AppleLocalModelError.modelAssetsUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertNotEqual(state, .installed)
            }
            XCTAssertEqual(inventory.queries, 1)
            XCTAssertEqual(inventory.installs, 0)
            XCTAssertEqual(inventory.sleeps, 0)
        }
    }

    func testPreparation_installsAndConfirmsInventoryAfterTransientStates() async throws {
        let inventory = Inventory([.supported, .downloading, .supported, .installed])
        try await AppleSpeechAssets.ensure(
            policy: .installIfNeeded,
            status: { await inventory.status() },
            install: { try await inventory.install() },
            sleep: { _ in await inventory.recordSleep() },
            onPreparing: { await inventory.recordPreparing() }
        )
        XCTAssertEqual(inventory.queries, 4)
        XCTAssertEqual(inventory.installs, 1)
        XCTAssertEqual(inventory.sleeps, 2)
        XCTAssertEqual(inventory.preparing, 1)
    }

    func testPreparation_installFailureCanRetryAndAlreadyInstalledNeedsNoRequest() async throws {
        let inventory = Inventory([.supported])
        inventory.failFirstInstall = true
        inventory.installCompletes = true
        func prepare() async throws {
            try await AppleSpeechAssets.ensure(
                policy: .installIfNeeded,
                status: { await inventory.status() },
                install: { try await inventory.install() },
                sleep: { _ in XCTFail("No wait expected") }
            )
        }
        do {
            try await prepare()
            XCTFail("Expected installation failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        try await prepare()
        try await prepare()
        XCTAssertEqual(inventory.installs, 2)
    }

    func testPreparation_supportedWithoutRequestFailsWithoutSleep() async {
        do {
            try await AppleSpeechAssets.ensure(
                policy: .installIfNeeded, status: { .supported }, install: { false },
                sleep: { _ in XCTFail("Nothing is being installed") }
            )
            XCTFail("Expected unavailable assets")
        } catch {
            guard case AppleLocalModelError.modelAssetsUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDefaultInstallCapableCaller_doesNotAdoptForegroundDeadline() async {
        let inventory = SpeechDependencyGate<AppleSpeechAssetStatus>("Default caller query")
        let task = Task {
            try await AppleSpeechAssets.ensure(
                policy: .installIfNeeded, status: { await inventory.wait() }, install: { false },
                deadlineSleep: { _ in XCTFail("Existing install-capable caller must keep its default policy") }
            )
        }
        await fulfillment(of: [inventory.entered], timeout: 2)
        inventory.release(.installed)
        do { try await task.value } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testInstalledOnly_cancellationRecoversBeforeUncooperativeInventoryReplies() async throws {
        let inventory = SpeechDependencyGate<AppleSpeechAssetStatus>("Inventory query")
        let settled = expectation(description: "Caller cancelled without inventory reply")
        let task = Task {
            do {
                try await AppleSpeechAssets.ensure(
                    policy: .installedOnly, status: { await inventory.wait() },
                    install: { XCTFail("Cancelled startup installed"); return false }
                )
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            settled.fulfill()
        }
        await fulfillment(of: [inventory.entered], timeout: 2)
        task.cancel()
        await fulfillment(of: [settled], timeout: 2)
        // A replacement succeeds while the original system request is still suspended.
        try await AppleSpeechAssets.ensure(policy: .installedOnly, status: { .installed }, install: { false })
        inventory.release(.installed)
        await task.value
    }

    func testInventoryDeadline_recoversWithoutReplyOrInstallation() async {
        for policy in [AppleSpeechAssetPolicy.installedOnly, .installIfNeeded] {
            let inventory = SpeechDependencyGate<AppleSpeechAssetStatus>("Inventory query")
            let deadline = SpeechDependencyGate<Void>("Deadline armed")
            let settled = expectation(description: "Timed out without inventory reply")
            let task = Task {
                do {
                    try await AppleSpeechAssets.ensure(
                        policy: policy, status: { await inventory.wait() },
                        install: { XCTFail("Unanswered query must not install"); return false },
                        sleep: { _ in XCTFail("Unanswered query must not poll") },
                        inventoryTimeout: .seconds(2), deadlineSleep: { _ in await deadline.wait() }
                    )
                    XCTFail("Expected unavailable assets")
                } catch {
                    guard case AppleLocalModelError.modelAssetsUnavailable = error else {
                        settled.fulfill()
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
                settled.fulfill()
            }
            await fulfillment(of: [inventory.entered, deadline.entered], timeout: 2)
            deadline.release(())
            await fulfillment(of: [settled], timeout: 2)
            inventory.release(.installed)
            await task.value
        }
    }
}
