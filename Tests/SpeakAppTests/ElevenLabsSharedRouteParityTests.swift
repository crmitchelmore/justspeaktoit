import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The former `ElevenLabsLiveController` behaviour, proven on the shared path.
/// ElevenLabs' wire protocol is covered by the SpeakCore and desktop suites;
/// these tests pin what the Mac host does with the client's results.
@MainActor
final class ElevenLabsSharedRouteParityTests: XCTestCase {
    func testAudioGoesToTheClientUnframedAndFinishesOnceWithoutAnotherCommit() async throws {
        let (fixture, client) = try makeFixture()
        try await fixture.start()
        let audio = Data([1, 0, 2, 0])
        client.sendAudio(audio)
        await fixture.controller.stop()
        XCTAssertEqual(client.audio, [audio])
        XCTAssertEqual(client.finishes, 1)
        XCTAssertEqual(client.stops, 0)
    }

    func testWholeFinishReplacesEarlierStandaloneSegmentsOnce() async throws {
        let (fixture, client) = try makeFixture()
        try await fixture.start()
        client.transcript?("Yes.", true)
        client.transcript?("Yes.", true)
        client.transcript?("trailing draft", false)
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.partials.last, "Yes. Yes. trailing draft")
        client.finishResult = "Yes. Yes. Trailing."
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.results.map(\.text), ["Yes. Yes. Trailing."])
        XCTAssertEqual(fixture.delegate.results.last?.modelIdentifier, "elevenlabs/scribe-v2-streaming")
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
    }

    func testNilWholeFinishKeepsConfirmedTextAndDraft() async throws {
        let (fixture, client) = try makeFixture()
        try await fixture.start()
        client.transcript?("Confirmed.", true)
        client.transcript?("draft", false)
        await fixture.controller.stop()
        XCTAssertEqual(fixture.delegate.results.last?.text, "Confirmed. draft")
    }

    func testFailedFinishKeepsTheVisibleDraftAndReportsOnce() async throws {
        let (fixture, client) = try makeFixture()
        try await fixture.start()
        client.transcript?("Confirmed.", true)
        client.transcript?("draft", false)
        client.onFinish = { client.error?(URLError(.networkConnectionLost)) }
        client.finishResult = "Confirmed, revised."
        await fixture.controller.stop()
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertEqual(fixture.delegate.partials.last, "Confirmed. draft")
    }

    func testStopGraceIsBoundedAndPrecedesTheFinish() async throws {
        let (bounded, _) = try makeFixture(grace: 500)
        try await bounded.start()
        XCTAssertEqual(
            bounded.controller.stopCompletionTimeout, ElevenLabsLiveClient.finishDrainBudget + 2 + 1,
            "The watchdog outlives the drain and the two-second bounded grace"
        )

        let (fixture, client) = try makeFixture(grace: 0.2)
        try await fixture.start()
        let began = Date()
        await fixture.controller.stop()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.finishStartedAt).timeIntervalSince(began), 0.2)
    }

    private func makeFixture(grace: TimeInterval = 0) throws -> (SharedClientParityFixture, ElevenLabsParityClient) {
        let client = ElevenLabsParityClient()
        let fixture = try SharedClientParityFixture(model: "elevenlabs/scribe-v2-streaming", stopGrace: grace) { _ in
            client
        }
        return (fixture, client)
    }
}

/// Stands in for `ElevenLabsLiveClient` with its declared contract.
final class ElevenLabsParityClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape: TranscriptFinalShape = .standaloneSegments
    var finishFlushesBufferedAudio: Bool { true }
    var finalisationBudget: TimeInterval? { ElevenLabsLiveClient.finishDrainBudget }
    var transcript: ((String, Bool) -> Void)?
    var error: ((Error) -> Void)?
    var finishResult: String?
    var onFinish: (() -> Void)?
    private(set) var audio: [Data] = []
    private(set) var finishes = 0
    private(set) var finishStartedAt: Date?
    private(set) var stops = 0

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        transcript = onTranscript
        error = onError
    }
    func sendAudio(_ data: Data) { audio.append(data) }
    func stop() { stops += 1 }
    func cancel() { stops += 1 }
    func finishAndWait() async -> String? {
        finishes += 1
        finishStartedAt = Date()
        onFinish?()
        return finishResult
    }
}
