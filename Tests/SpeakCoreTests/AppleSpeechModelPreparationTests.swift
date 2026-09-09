import XCTest
@testable import SpeakCore

@MainActor
final class AppleSpeechModelPreparationTests: XCTestCase {
    private typealias Preparation = AppleSpeechModelPreparation
    private let first = Preparation.Configuration(modelID: "speech", localeIdentifier: "en-GB")
    private let second = Preparation.Configuration(modelID: "dictation", localeIdentifier: "fr-FR")

    func testConcurrentRequests_resolvedConfigurationSharesOnePreparation() async {
        for selection in [first, second] {
            let started = expectation(description: "Preparing")
            let joined = expectation(description: "Second caller resolved")
            var finish: CheckedContinuation<Void, Never>?
            var installs = 0
            let resolved = first
            let operations = AppleSpeechPreparationOperations { _ in

                Preparation.Operation(configuration: resolved) { onPreparing in
                    installs += 1
                    onPreparing()
                    await withCheckedContinuation { finish = $0; started.fulfill() }
                }
            }
            let preparation = Preparation(operations: operations)
            let other = Preparation(operations: operations)
            let observation = other.$state.sink { if $0 == .preparing { joined.fulfill() } }
            let firstTask = Task { await preparation.prepare(first) }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(preparation.state, .preparing)
            // A different requested engine/locale resolves to the same actual module configuration.
            let secondTask = Task { await other.prepare(selection) }
            await fulfillment(of: [joined], timeout: 2)
            XCTAssertEqual(preparation.state, .preparing)
            XCTAssertEqual(installs, 1)
            finish?.resume()
            await firstTask.value
            await secondTask.value
            XCTAssertEqual(preparation.state, .ready(resolved))
            XCTAssertEqual(other.state, .ready(resolved))
            XCTAssertEqual(other.selection, selection)
            withExtendedLifetime(observation) {}
        }
    }

    func testSelectionChange_ignoresLateCompletionAndDoesNotAutomaticallyPrepare() async {
        let started = expectation(description: "Preparing")
        var finish: CheckedContinuation<Void, Never>?
        var installs = 0
        let preparation = Preparation { configuration in
            Preparation.Operation(configuration: configuration) { onPreparing in
                installs += 1
                onPreparing()
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        preparation.select(first)
        XCTAssertEqual(installs, 0)
        let task = Task { await preparation.prepare(first) }
        await fulfillment(of: [started], timeout: 2)
        preparation.select(second)
        // Returning to the first configuration still invalidates the original request's completion.
        preparation.select(first)
        finish?.resume()
        await task.value
        XCTAssertEqual(preparation.state, .idle)
        XCTAssertEqual(installs, 1)
    }

    func testFailure_retryRechecksAndSuccessfulPreparationIsNotReadinessCache() async {
        var attempts = 0
        let preparation = Preparation { configuration in
            Preparation.Operation(configuration: configuration) { _ in
                attempts += 1
                if attempts == 1 { throw URLError(.notConnectedToInternet) }
            }
        }
        await preparation.prepare(first)
        guard case .failed = preparation.state else { return XCTFail("Failure should offer retry") }
        await preparation.prepare(first)
        XCTAssertEqual(preparation.state, .ready(first))
        await preparation.prepare(first)
        XCTAssertEqual(attempts, 3)
    }

    func testCancelledButtonTask_doesNotEvenResolveOrChangeSelection() async {
        let preparation = Preparation { configuration in
            XCTFail("A button task cancelled before execution must not prepare")
            return Preparation.Operation(configuration: configuration) { _ in }
        }
        preparation.select(second)
        let task = Task { await preparation.prepare(first) }
        task.cancel()
        await task.value
        XCTAssertEqual(preparation.selection, second)
        XCTAssertEqual(preparation.state, .idle)
    }

    func testLeavingSettingsDuringResolution_neverStartsInstallationOrPublishesReady() async {
        let started = expectation(description: "Resolving")
        var finish: CheckedContinuation<Void, Never>?
        var installs = 0
        let preparation = Preparation { configuration in
            await withCheckedContinuation { finish = $0; started.fulfill() }
            return Preparation.Operation(configuration: configuration) { _ in installs += 1 }
        }
        let cancelled = expectation(description: "Cancelled before resolution reply")
        let task = Task { await preparation.prepare(first); cancelled.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(preparation.state, .checking)
        preparation.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        finish?.resume()
        await task.value
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(preparation.state, .idle)
    }

    func testLeavingSettingsDuringPreparation_cancelsAndAllowsRetry() async {
        let started = expectation(description: "Preparing")
        var attempts = 0
        let preparation = Preparation { configuration in
            Preparation.Operation(configuration: configuration) { onPreparing in
                attempts += 1
                if attempts == 1 {
                    onPreparing()
                    started.fulfill()
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }
        let task = Task { await preparation.prepare(first) }
        await fulfillment(of: [started], timeout: 2)
        preparation.cancel()
        await task.value
        XCTAssertEqual(preparation.state, .idle)
        await preparation.prepare(first)
        XCTAssertEqual(preparation.state, .ready(first))
        XCTAssertEqual(attempts, 2)
    }
}
