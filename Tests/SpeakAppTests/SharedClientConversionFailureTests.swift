import AVFoundation
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Lost capture audio must reach the session owner, once per run, without
/// erasing the text already transcribed (review B finding 5).
@MainActor
final class SharedClientConversionFailureTests: XCTestCase {
    func testConversionFailureFailsTheRunOnceAndKeepsTheVisibleText() async throws {
        let fixture = try SharedClientParityFixture(model: "elevenlabs/scribe-v2-streaming") { _ in
            ElevenLabsParityClient()
        }
        var report: (@Sendable (Error) -> Void)?
        fixture.controller.observeConversionFailureReporter = { report = $0 }
        try await fixture.start()
        let client = try XCTUnwrap(fixture.client as? ElevenLabsParityClient)
        client.transcript?("Kept words.", true)
        let failure = LivePCMConversionError.conversionFailed(domain: NSOSStatusErrorDomain, code: -50)
        try XCTUnwrap(report)(failure)
        try XCTUnwrap(report)(failure)
        fixture.updates.deliverAll()

        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertEqual(fixture.delegate.errors.first as? LivePCMConversionError, failure)
        XCTAssertEqual(fixture.delegate.partials.last, "Kept words.")

        await fixture.controller.stop()
        fixture.updates.deliverAll()
        XCTAssertEqual(fixture.delegate.errors.count, 1, "Stop does not report the same failure again")
        XCTAssertTrue(fixture.delegate.results.isEmpty, "Lost audio is never reported as a complete result")
        XCTAssertEqual(fixture.delegate.partials.last, "Kept words.")
    }

    func testProcessorReportsTheFirstFailureOfEachRunOnly() throws {
        let processor = SharedClientAudioProcessor()
        let reports = FailureLog()
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
        buffer.frameLength = 480
        // No converter exists from float PCM to an MP3 encoder on macOS.
        let unconvertible = try XCTUnwrap(AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEGLayer3, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ]))
        let client = ElevenLabsParityClient()

        processor.setRunning(true, onConversionFailure: { reports.append($0) })
        processor.convertAndSend(buffer, to: unconvertible, client: client)
        processor.convertAndSend(buffer, to: unconvertible, client: client)
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports.first is LivePCMConversionError)
        XCTAssertTrue(client.audio.isEmpty, "Nothing unconverted reaches the provider")

        processor.setRunning(false)
        processor.setRunning(true, onConversionFailure: { reports.append($0) })
        processor.convertAndSend(buffer, to: unconvertible, client: client)
        XCTAssertEqual(reports.count, 2, "A new run reports its own first failure")
        processor.setRunning(false)
    }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    var count: Int { lock.withLock { errors.count } }
    var first: Error? { lock.withLock { errors.first } }
    func append(_ error: Error) { lock.withLock { errors.append(error) } }
}
