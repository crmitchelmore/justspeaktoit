import Foundation
import XCTest
@testable import SpeakApp
@testable import SpeakCore

/// Configured replacements for the first four legacy Mac finalization
/// contracts. The legacy implementations/tests remain intact until qualified.
@MainActor
final class GladiaConfiguredMacFinalizationTests: XCTestCase {
    func testConfiguredStopWaitsPastAcknowledgementAndAllFinalsUntilActualEndSession() async throws {
        let fixture = try ConfiguredGladiaControllerFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        socket.emit(try frame("First.", id: "1", confidence: 0.9))
        let stopping = try await fixture.beginStop(in: self)
        XCTAssertEqual(fixture.client.finalisationBudget, 3.75)
        XCTAssertEqual(socket.binary.map(\.count), [3_200])
        socket.emit(#"{"type":"acknowledgment","data":{"type":"stop_recording"}}"#)
        socket.emit(try frame("Second.", id: "2", confidence: 0.8))
        socket.emit(try frame("Third.", id: "3", confidence: 0.7))
        XCTAssertFalse(stopping.settlement.settled, "Ack and finals are not the terminal session event")
        try await fixture.finish(stopping, completeControl: false)
        let result = try XCTUnwrap(fixture.delegate.results.first)
        XCTAssertEqual(fixture.delegate.results.count, 1)
        XCTAssertEqual(result.text, "First. Second. Third.")
        XCTAssertEqual(result.segments.map(\.text), ["First.", "Second.", "Third."])
        XCTAssertEqual(result.segments.compactMap(\.confidence), [0.9, 0.8, 0.7])
        XCTAssertEqual(try XCTUnwrap(result.confidence), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(fixture.delegate.events, [
            .partial("First."), .boundary("First."), .partial("First. Second."), .boundary("Second."),
            .partial("First. Second. Third."), .boundary("Third.")
        ])
        XCTAssertEqual(socket.controls, [ConfiguredGladiaControllerFixture.stopJSON])
        XCTAssertEqual(socket.cancels, 1)
        try socket.completeSend(URLError(.networkConnectionLost))
        fixture.clock.takeActions().forEach { $0() }
        fixture.updates.deliverAll(reversed: true)
        XCTAssertTrue(fixture.delegate.errors.isEmpty)
        XCTAssertEqual(fixture.delegate.results.count, 1)
    }

    func testConfiguredStopSendFailureKeepsNewFinalConfidenceAndDraftBeforeSoleFailure() async throws {
        let fixture = try ConfiguredGladiaControllerFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        socket.emit(try frame("Confirmed.", id: "1", confidence: 0.9))
        let stopping = try await fixture.beginStop(in: self)
        socket.emit(try frame("New tail.", id: "2", confidence: 0.75))
        socket.emit(try frame("retained draft", id: "3", final: false, confidence: 0.5))
        try socket.completeSend(URLError(.networkConnectionLost))
        try await fixture.wait(stopping.done)
        await stopping.task.value
        XCTAssertEqual(fixture.delegate.events, [
            .partial("Confirmed."), .boundary("Confirmed."),
            .partial("Confirmed. New tail."), .boundary("New tail."),
            .partial("Confirmed. New tail. retained draft"), .error
        ])
        XCTAssertEqual(fixture.delegate.updates.last?.confidence, 0.5)
        let retained = fixture.client.transcriptSnapshot(captureDuration: 0)
        XCTAssertEqual(retained.segments.map(\.text), ["Confirmed.", "New tail."])
        XCTAssertEqual(retained.segments.compactMap(\.confidence), [0.9, 0.75])
        XCTAssertEqual(retained.resolvedDisplayText, "Confirmed. New tail. retained draft")
        XCTAssertEqual(fixture.delegate.errors.first as? GladiaStreamingError, .connectionLost)
        fixture.updates.deliverAll(reversed: true)
        fixture.clock.takeActions().forEach { $0() }
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty, "Failed text is retained, never reported as success")
        XCTAssertEqual(socket.cancels, 1)
    }

    func testConfiguredFinalWindowRetainsDraftAndReportsMissingCompletionWithinDeclaredBudget() async throws {
        let fixture = try ConfiguredGladiaControllerFixture(grace: 0, window: nil)
        defer { fixture.cleanup() }
        try await fixture.start()
        let socket = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        socket.emit(try frame("draft", id: "draft", final: false, confidence: 0.6))
        let stopping = try await fixture.beginStop(in: self)
        XCTAssertEqual(fixture.client.finalisationBudget, 4.5, "Configured stages deliberately differ from legacy5s")
        XCTAssertEqual(fixture.controller.stopCompletionTimeout, 10)
        try socket.completeSend()
        XCTAssertEqual(fixture.clock.count(fixture.window), 2, "Retired control and actual final window share1.5s")
        XCTAssertEqual(fixture.clock.fire(fixture.window), 2)
        try await fixture.wait(stopping.done)
        await stopping.task.value
        XCTAssertEqual(fixture.delegate.events, [.partial("draft"), .error])
        XCTAssertEqual(fixture.delegate.updates.last?.confidence, 0.6)
        XCTAssertEqual(fixture.delegate.errors.first as? GladiaStreamingError, .missingCompletion)
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        XCTAssertEqual(socket.cancels, 1)
        fixture.clock.takeActions().forEach { $0() }
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1)
    }

    func testConfiguredOldReceiverSendAndTimersCannotMutateRestartedControllerRun() async throws {
        let fixture = try ConfiguredGladiaControllerFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let old = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        old.emit(try frame("Old.", id: "old"))
        let stopping = try await fixture.beginStop(in: self)
        let oldReceiver = try XCTUnwrap(old.takeReceiver())
        let oldTimers = fixture.clock.takeActions()
        stopping.task.cancel()
        try await fixture.wait(stopping.done)
        await stopping.task.value
        XCTAssertTrue(fixture.delegate.errors.last is CancellationError)
        XCTAssertTrue(fixture.delegate.results.isEmpty)
        fixture.updates.deliverAll(reversed: true)
        let replacement = GladiaControllerBoundaryDelegate()
        fixture.controller.delegate = replacement
        try await fixture.start()
        let current = try XCTUnwrap(fixture.socket)
        try fixture.admitPCM()
        oldReceiver(.success(.text(try frame("Leaked old tail.", id: "late"))))
        try old.completeSend(URLError(.networkConnectionLost))
        oldTimers.forEach { $0() }
        current.emit(try frame("Current.", id: "current", confidence: 0.95))
        fixture.updates.deliverAll(reversed: true)
        XCTAssertEqual(replacement.events, [.partial("Current."), .boundary("Current.")])
        XCTAssertTrue(replacement.errors.isEmpty)
        XCTAssertTrue(replacement.results.isEmpty)
        XCTAssertEqual(current.cancels, 0)
        let next = try await fixture.beginStop(in: self)
        try await fixture.finish(next)
        XCTAssertEqual(replacement.results.map(\.text), ["Current."])
        XCTAssertTrue(replacement.errors.isEmpty)
    }

    private func frame(_ text: String, id: String, final: Bool = true, confidence: Double = 0.8) throws -> String {
        try GladiaControllerBoundaryFixture.frame(text, id: id, final: final, confidence: confidence)
    }
}
