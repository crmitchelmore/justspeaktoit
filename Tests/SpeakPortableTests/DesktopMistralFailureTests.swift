import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopMistralFailureTests: DeepgramSpeechStubTestCase {
    func testLateChunkFailure_RejectsPartialAudioButRetainsActualAttemptMeasurements() async throws {
        let inventory = try await listed()
        let payload = try responseAudio(DeepgramSpeechFixture.canonicalWAV(pcm: pcm))
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: StubURLProtocol.body(of: request)) as? [String: Any])
            return .respond(DeepgramSpeechFixture.response(request),
                            body["input"] as? String == "x" ? Data(#"{"audio_data":""}"#.utf8) : payload)
        }
        let source = try longSource()
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, inventory: inventory)
            }
            XCTFail("A failed second chunk returned partial audio")
        } catch {
            XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
        }
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertEqual(capture.records.first?.audioDuration, Double(pcm.count) / 48_000)
        XCTAssertNil(capture.records.last?.audioDuration)
        XCTAssertTrue(capture.records.allSatisfy { $0.historyRecordID == nil && $0.reportedInputTokens == nil })
    }

    func testCancellation_StopsOwnedTransportAndPreventsNextChunkOrPublication() async throws {
        let inventory = try await listed()
        StubURLProtocol.resetRecordedRequests()
        let started = expectation(description: "Synthetic Mistral request admitted")
        let stopped = expectation(description: "Synthetic Mistral request cancelled")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        let source = try longSource()
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        let task = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(source, inventory: inventory)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled audio returned") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(capture.records.map(\.outcome), [.cancelled])
        XCTAssertNil(capture.records.first?.audioDuration)
    }

    func testMalformedTruncatedAndOversizedBodies_AndTypedTransportFailuresRemainExplicit() async throws {
        let inventory = try await listed()
        let wave = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        let payloads = [
            Data(), Data(#"{"audio_data":"AAAA""#.utf8),
            try responseAudio(Data(wave.dropLast())),
            try responseAudio(Data("not a WAV".utf8))
        ]
        for payload in payloads {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), payload) }
            do {
                _ = try await synthesize(longSource(), inventory: inventory)
                XCTFail("Invalid body admitted")
            } catch {
                XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
            }
        }
        let excessive = Data(repeating: 65, count: DeepgramSpeechSynthesizer.defaultResponseLimit + 1)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), excessive) }
        do { _ = try await synthesize(longSource(), inventory: inventory); XCTFail("Oversized body admitted") } catch {
            XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge)
        }
        StubURLProtocol.handler = {
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap($0.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": String(DeepgramSpeechSynthesizer.defaultResponseLimit + 1)])), Data())
        }
        do {
            _ = try await synthesize(longSource(), inventory: inventory)
            XCTFail("Oversized length admitted")
        } catch {
            XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge)
        }
        for (code, expected) in [
            (URLError.Code.timedOut, DesktopSpeechSynthesisError.timedOut),
            (.cannotConnectToHost, .transportFailure)
        ] {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            do {
                _ = try await synthesize(longSource(), inventory: inventory)
                XCTFail("Transport failure admitted")
            } catch {
                XCTAssertEqual(error as? DesktopSpeechSynthesisError, expected)
            }
        }
    }

    private func listed() async throws -> VoiceAccountInventory {
        let data = try JSONSerialization.data(withJSONObject: [
            "items": [["id": "019b2bd7-96e7-7219-8c0b-45a73da50088", "name": "Synthetic account voice"]]
        ])
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), data) }
        return try await .fetch(provider: .mistral, session: session) { "synthetic-key" }
    }

    private func longSource() throws -> VoiceOutputSourceSnapshot {
        try .init(source: .typedText, text: String(repeating: "x", count: MistralTTSAPI.maxInputCharacters + 1))
    }

    private func responseAudio(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["audio_data": data.base64EncodedString()])
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot, inventory: VoiceAccountInventory
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: XCTUnwrap(inventory.desktopVoices.first), options: VoiceSynthesisOptions(),
            accountInventory: inventory, credential: { "synthetic-key" })
    }
}
