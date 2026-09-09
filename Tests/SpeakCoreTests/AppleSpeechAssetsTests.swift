import XCTest
@testable import SpeakCore

final class AppleSpeechAssetsTests: XCTestCase {
    func testInstalledOnly_allStatesNeverInstallOrPoll() async {
        for state in [AppleSpeechAssetStatus.supported, .downloading, .unsupported, .installed] {
            var queries = 0
            var installs = 0
            var sleeps = 0
            do {
                try await AppleSpeechAssets.ensure(
                    policy: .installedOnly,
                    status: { queries += 1; return state },
                    install: { installs += 1; return true },
                    sleep: { _ in sleeps += 1 },
                    onPreparing: { XCTFail("Live startup must not prepare assets") }
                )
                XCTAssertEqual(state, .installed)
            } catch {
                guard case AppleLocalModelError.modelAssetsUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertNotEqual(state, .installed)
            }
            XCTAssertEqual(queries, 1)
            XCTAssertEqual(installs, 0)
            XCTAssertEqual(sleeps, 0)
        }
    }

    func testPreparation_installsAndConfirmsInventoryAfterTransientStates() async throws {
        var states: [AppleSpeechAssetStatus] = [.supported, .downloading, .supported, .installed]
        var installs = 0
        var sleeps = 0
        var preparing = 0
        try await AppleSpeechAssets.ensure(
            policy: .installIfNeeded,
            status: { states.removeFirst() },
            install: { installs += 1; return true },
            sleep: { _ in sleeps += 1 },
            onPreparing: { preparing += 1 }
        )
        XCTAssertTrue(states.isEmpty)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(sleeps, 2)
        XCTAssertEqual(preparing, 1)
    }

    func testPreparation_installFailureCanRetryAndAlreadyInstalledNeedsNoRequest() async throws {
        var state = AppleSpeechAssetStatus.supported
        var attempts = 0
        func prepare() async throws {
            try await AppleSpeechAssets.ensure(
                policy: .installIfNeeded,
                status: { state },
                install: {
                    attempts += 1
                    if attempts == 1 { throw URLError(.notConnectedToInternet) }
                    state = .installed
                    return true
                },
                sleep: { _ in XCTFail("No wait expected") }
            )
        }
        do {
            try await prepare()
            XCTFail("Expected installation failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        try await prepare()
        try await prepare()
        XCTAssertEqual(attempts, 2)
    }

    func testPreparation_supportedWithoutRequestFailsWithoutSleep() async {
        do {
            try await AppleSpeechAssets.ensure(
                policy: .installIfNeeded,
                status: { .supported },
                install: { false },
                sleep: { _ in XCTFail("Nothing is being installed") }
            )
            XCTFail("Expected unavailable assets")
        } catch {
            guard case AppleLocalModelError.modelAssetsUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testInstalledOnly_cancellationDuringInventoryWinsOverStatus() async {
        for state in [AppleSpeechAssetStatus.supported, .installed] {
            let checking = expectation(description: "Inventory query")
            var reply: CheckedContinuation<AppleSpeechAssetStatus, Never>?
            let task = Task {
                try await AppleSpeechAssets.ensure(
                    policy: .installedOnly,
                    status: {
                        await withCheckedContinuation { reply = $0; checking.fulfill() }
                    },
                    install: { XCTFail("Cancelled startup installed"); return false },
                    sleep: { _ in XCTFail("Cancelled startup polled") }
                )
            }
            await fulfillment(of: [checking], timeout: 2)
            task.cancel()
            reply?.resume(returning: state)
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}
