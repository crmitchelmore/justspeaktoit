import XCTest
@testable import SpeakCore

@MainActor
final class AppleSpeechPreparationRecoveryTests: XCTestCase {
    private typealias Preparation = AppleSpeechModelPreparation
    private let configuration = Preparation.Configuration(modelID: "speech", localeIdentifier: "en-GB")

    func testCancelledUncooperativeInstall_canRetryBeforeOldReplyAndIgnoresOldProgressAndCompletion() async {
        let old = SpeechDependencyGate<Void>("First install suspended")
        let replacement = SpeechDependencyGate<Void>("Replacement install suspended")
        let retired = expectation(description: "First caller cancelled")
        let late = expectation(description: "Old operation replied")
        let ready = expectation(description: "Replacement caller completed")
        var attempts = 0
        let preparation = Preparation { configuration in
            Preparation.Operation(configuration: configuration) { onPreparing in
                attempts += 1
                if attempts == 1 {
                    onPreparing()
                    await old.wait()
                    onPreparing() // A misbehaving dependency can report late progress as well as success.
                    late.fulfill()
                } else {
                    await replacement.wait()
                }
            }
        }
        Task { await preparation.prepare(configuration); retired.fulfill() }
        await fulfillment(of: [old.entered], timeout: 2)
        preparation.cancel()
        Task { await preparation.prepare(configuration); ready.fulfill() }
        await fulfillment(of: [retired, replacement.entered], timeout: 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(preparation.state, .checking)
        old.release(())
        await fulfillment(of: [late], timeout: 2)
        XCTAssertEqual(preparation.state, .checking, "A retired operation cannot publish progress for its replacement")
        replacement.release(())
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(preparation.state, .ready(configuration), "Old cleanup must not remove a replacement entry")
    }

    func testStalledInstall_deadlineReleasesPendingEntryAndRetryCanSucceedBeforeOldReply() async {
        let install = SpeechDependencyGate<Void>("Install suspended")
        let deadline = SpeechDependencyGate<Void>("Preparation deadline armed")
        let failed = expectation(description: "Preparation failed before install returns")
        let late = expectation(description: "Old install returned")
        var attempts = 0
        let operations = AppleSpeechPreparationOperations(sleep: { duration in
            if duration == AppleSpeechDependencyWait.preparationTimeout {
                await deadline.wait()
            } else {
                try await Task.sleep(for: .seconds(30))
            }
        }, resolve: { configuration in
            Preparation.Operation(configuration: configuration) { onPreparing in
                attempts += 1
                if attempts == 1 {
                    onPreparing()
                    await install.wait()
                    late.fulfill()
                }
            }
        })
        let preparation = Preparation(operations: operations)
        Task { await preparation.prepare(configuration); failed.fulfill() }
        await fulfillment(of: [install.entered, deadline.entered], timeout: 2)
        deadline.release(())
        await fulfillment(of: [failed], timeout: 2)
        guard case .failed = preparation.state else {
            install.release(())
            return XCTFail("Expected retryable failure")
        }
        await preparation.prepare(configuration)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(preparation.state, .ready(configuration))
        install.release(())
        await fulfillment(of: [late], timeout: 2)
        deadline.release(()) // Release the cancelled second deadline, which intentionally ignores cancellation.
        XCTAssertEqual(preparation.state, .ready(configuration))
    }

    func testUnansweredResolution_deadlineAllowsRetryAndOldReplyCannotInstall() async {
        let resolution = SpeechDependencyGate<Void>("Resolution suspended")
        let deadline = SpeechDependencyGate<Void>("Resolution deadline armed")
        let failed = expectation(description: "Failed before resolution reply")
        let late = expectation(description: "Old resolution returned")
        var resolutions = 0
        var installs = 0
        let operations = AppleSpeechPreparationOperations(sleep: { duration in
            if duration == AppleSpeechDependencyWait.inventoryTimeout {
                await deadline.wait()
            } else {
                try await Task.sleep(for: .seconds(30))
            }
        }, resolve: { configuration in
            resolutions += 1
            if resolutions == 1 { await resolution.wait(); late.fulfill() }
            return Preparation.Operation(configuration: configuration) { _ in installs += 1 }
        })
        let preparation = Preparation(operations: operations)
        Task { await preparation.prepare(configuration); failed.fulfill() }
        await fulfillment(of: [resolution.entered, deadline.entered], timeout: 2)
        deadline.release(())
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(installs, 0)
        await preparation.prepare(configuration)
        XCTAssertEqual(preparation.state, .ready(configuration))
        resolution.release(())
        await fulfillment(of: [late], timeout: 2)
        deadline.release(())
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(preparation.state, .ready(configuration))
    }

    func testDepartingCaller_doesNotCancelOtherCallerForSameOrDifferentConfiguration() async {
        for sameConfiguration in [true, false] {
            await assertIndependentCallers(sameConfiguration: sameConfiguration)
        }
    }

    private func assertIndependentCallers(sameConfiguration: Bool) async {
        let first = SpeechDependencyGate<Void>("First install suspended")
        let second = SpeechDependencyGate<Void>("Other install suspended")
        let departed = expectation(description: "Departing caller returned")
        let joined = expectation(description: "Other caller preparing")
        let completed = expectation(description: "Other caller ready")
        let otherConfiguration = sameConfiguration ? configuration : Preparation.Configuration(
            modelID: "dictation", localeIdentifier: "fr-FR"
        )
        var attempts = 0
        let selected = configuration
        let operations = AppleSpeechPreparationOperations { configuration in
            Preparation.Operation(configuration: configuration) { progress in
                attempts += 1
                progress()
                if configuration == selected { await first.wait() } else { await second.wait() }
            }
        }
        let caller = Preparation(operations: operations)
        let other = Preparation(operations: operations)
        let observation = other.$state.sink { if $0 == .preparing { joined.fulfill() } }
        Task { await caller.prepare(configuration); departed.fulfill() }
        await fulfillment(of: [first.entered], timeout: 2)
        Task { await other.prepare(otherConfiguration); completed.fulfill() }
        await fulfillment(of: [joined], timeout: 2)
        if !sameConfiguration { await fulfillment(of: [second.entered], timeout: 2) }
        caller.cancel()
        await fulfillment(of: [departed], timeout: 2)
        XCTAssertEqual(caller.state, .idle)
        XCTAssertEqual(other.state, .preparing)
        XCTAssertEqual(attempts, sameConfiguration ? 1 : 2)
        first.release(())
        second.release(())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(other.state, .ready(otherConfiguration))
        XCTAssertEqual(caller.state, .idle)
        withExtendedLifetime(observation) {}
    }
}
