#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakiOSLib

@MainActor
final class OpenRouterIOSProgressiveVoiceOutputTests: XCTestCase {
    private let selection = OpenRouterSpeechSelection(modelID: "example/speech", voice: "voice")

    func testRecordingRefusalOccursBeforeHTTPWithoutAttemptingFileFallback() async throws {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in XCTFail("Recording refusal must precede HTTP"); return .hang }
        var dependencies = OpenRouterIOSProgressivePlayback.Dependencies()
        dependencies.acquireLease = { throw OpenRouterIOSVoiceOutputError.recordingInProgress }
        dependencies.makeOutput = { XCTFail("Recording refusal must precede native output"); throw FixtureError.setup }
        dependencies.activate = { XCTFail("Recording refusal must not activate audio") }
        let client = OpenRouterIOSVoiceOutputClient(
            session: session, progressiveSpeech: try XCTUnwrap(.init(selectionID: selection.id)),
            makeProgressivePlayback: { OpenRouterIOSProgressivePlayback(dependencies: dependencies) }
        )
        do {
            try await client.speak(text: "Hello", apiKey: "synthetic", selectionID: selection.id, speed: 1)
            XCTFail("Recording must refuse voice output")
        } catch {
            guard case OpenRouterIOSVoiceOutputError.recordingInProgress = error else { return XCTFail("Wrong error") }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertFalse(client.isSpeaking)
    }

    func testSessionInterruptionCancelsOwnedHeldHTTPAndPreservesInterruptedOutcome() async throws {
        let started = expectation(description: "Commissioned request began")
        let stopped = expectation(description: "Interrupted transport cancelled")
        let returned = expectation(description: "Interrupted caller returned")
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let notifications = NotificationCenter()
        var starts = 0
        var stops = 0
        var dependencies = OpenRouterIOSProgressivePlayback.Dependencies()
        dependencies.acquireLease = { nil }
        dependencies.activate = {}
        dependencies.notifications = notifications
        dependencies.makeOutput = {
            .init(start: { starts += 1 }, schedule: { _, _ in XCTFail("Held response has no PCM") },
                  stop: { stops += 1 })
        }
        let client = OpenRouterIOSVoiceOutputClient(
            session: session, progressiveSpeech: try XCTUnwrap(.init(selectionID: selection.id)),
            makeProgressivePlayback: { OpenRouterIOSProgressivePlayback(dependencies: dependencies) }
        )
        let task = Task {
            defer { returned.fulfill() }
            do {
                try await client.speak(text: "Hello", apiKey: "synthetic", selectionID: selection.id, speed: 1)
                XCTFail("Interrupted synthesis must not succeed")
            } catch {
                guard case OpenRouterIOSVoiceOutputError.interrupted = error else { return XCTFail("Wrong error") }
            }
        }
        defer { task.cancel(); client.stop() }
        let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(startResult, .completed)
        XCTAssertEqual(starts, 1)
        notifications.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let result = await XCTWaiter.fulfillment(of: [stopped, returned], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertFalse(client.isSpeaking)
    }

    func testPreHTTPSetupFailureUsesOneFileSynthesisRequestAndCancellationClosesIt() async throws {
        let started = expectation(description: "Single fallback request began")
        let stopped = expectation(description: "Fallback request cancelled")
        let returned = expectation(description: "Fallback caller returned")
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        var dependencies = OpenRouterIOSProgressivePlayback.Dependencies()
        dependencies.acquireLease = { nil }
        dependencies.makeOutput = { throw FixtureError.setup }
        dependencies.activate = { XCTFail("Failed setup cannot activate audio") }
        let client = OpenRouterIOSVoiceOutputClient(
            session: session, progressiveSpeech: try XCTUnwrap(.init(selectionID: selection.id)),
            makeProgressivePlayback: { OpenRouterIOSProgressivePlayback(dependencies: dependencies) }
        )
        let task = Task {
            defer { returned.fulfill() }
            do {
                try await client.speak(text: "Hello", apiKey: "synthetic", selectionID: selection.id, speed: 1)
                XCTFail("Held fallback must cancel")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        defer { task.cancel(); client.stop() }
        let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(startResult, .completed)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/audio/speech")
        task.cancel()
        let stopResult = await XCTWaiter.fulfillment(of: [stopped, returned], timeout: 2)
        XCTAssertEqual(stopResult, .completed)
        XCTAssertFalse(client.isSpeaking)
    }

    func testDefaultDisabledOtherSelectionAndNonunitSpeedNeverCreateProgressiveOutput() async throws {
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: selection.id))
        let scenarios: [AdmissionScenario] = [
            .init(option: .disabled, identifier: selection.id, speed: 1),
            .init(option: option, identifier: selection.id, speed: 1.2),
            .init(option: option, identifier: selection.id, speed: .nan),
            .init(option: option, identifier: OpenRouterSpeechSelection(modelID: "example/other", voice: "voice").id,
                  speed: 1)
        ]
        for scenario in scenarios {
            let started = expectation(description: "File route began")
            let returned = expectation(description: "File route returned")
            let session = StubURLProtocol.makeSession()
            StubURLProtocol.handler = { _ in .hang }
            StubURLProtocol.onStartLoading = { started.fulfill() }
            let client = OpenRouterIOSVoiceOutputClient(
                session: session, progressiveSpeech: scenario.option, makeProgressivePlayback: {
                    XCTFail("Only the exact commissioned selection at unit speed may create progressive output")
                    var inert = OpenRouterIOSProgressivePlayback.Dependencies()
                    inert.acquireLease = { nil }
                    inert.makeOutput = { throw FixtureError.setup }
                    inert.activate = {}
                    return OpenRouterIOSProgressivePlayback(dependencies: inert)
                }
            )
            let task = Task {
                defer { returned.fulfill() }
                do {
                    try await client.speak(
                        text: "Hello", apiKey: "synthetic", selectionID: scenario.identifier, speed: scenario.speed
                    )
                    XCTFail("Held request must cancel")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
            let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(startResult, .completed)
            task.cancel()
            client.stop()
            let result = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
            XCTAssertEqual(result, .completed)
            session.invalidateAndCancel()
            StubURLProtocol.reset()
        }
    }

    func testCancelledQueuedClientStartDoesNotStopPriorSynthesis() async throws {
        let session = StubURLProtocol.makeSession()
        let client = OpenRouterIOSVoiceOutputClient(session: session)
        try await assertCancelledQueuedStartPreservesPendingRequest(session: session, stop: { client.stop() }, speak: {
            try await client.speak(text: "Hello", apiKey: "synthetic", selectionID: self.selection.id, speed: 1)
        })
    }

    func testCancelledQueuedRouterStartDoesNotStopPriorSynthesis() async throws {
        let session = StubURLProtocol.makeSession()
        let router = VoiceOutputRouter(session: session)
        try await assertCancelledQueuedStartPreservesPendingRequest(session: session, stop: { router.stop() }, speak: {
            try await router.speak(
                text: "Hello", provider: .openrouter, model: self.selection.id, voice: "voice",
                lastKnownVoiceName: nil, speed: 1, languageIdentifier: "en", sonioxRegion: .unitedStates,
                deepgramAPIKey: "", sonioxAPIKey: "", openRouterAPIKey: "synthetic"
            )
        })
    }

    private func assertCancelledQueuedStartPreservesPendingRequest(
        session: URLSession, stop: @escaping () -> Void, speak: @escaping () async throws -> Void
    ) async throws {
        let started = expectation(description: "Prior request began")
        let firstReturned = expectation(description: "Prior request returned")
        let queuedReturned = expectation(description: "Cancelled queued request refused")
        let transportStopped = expectation(description: "Explicit stop cancelled prior transport")
        let observation = ProgressiveTransportObservation()
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { observation.stop(); transportStopped.fulfill() }
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        let prior = Task {
            defer { firstReturned.fulfill() }
            do { try await speak(); XCTFail("Held prior request must cancel") } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        defer { prior.cancel(); stop() }
        let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(startResult, .completed)
        let queued = Task { @MainActor in
            defer { queuedReturned.fulfill() }
            do { try await speak(); XCTFail("Cancelled queued start must refuse") } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        queued.cancel()
        let queuedResult = await XCTWaiter.fulfillment(of: [queuedReturned], timeout: 2)
        XCTAssertEqual(queuedResult, .completed)
        XCTAssertEqual(observation.stops, 0, "Refused caller must not stop the prior transport")
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        stop()
        let stopResult = await XCTWaiter.fulfillment(of: [transportStopped, firstReturned], timeout: 2)
        XCTAssertEqual(stopResult, .completed)
        XCTAssertEqual(observation.stops, 1)
    }

    private struct AdmissionScenario {
        let option: OpenRouterProgressiveSpeechOption
        let identifier: String
        let speed: Double
    }

    private enum FixtureError: Error { case setup }
}

private final class ProgressiveTransportObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var stops: Int { lock.withLock { count } }
    func stop() { lock.withLock { count += 1 } }
}
#endif
