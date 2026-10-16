import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopSonioxSpeechTests: DeepgramSpeechStubTestCase {
    func testRegionalCompleteWAV_UsesCapturedOptionsAndMeasuredUsageForEverySource() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for region in SonioxTTSRegion.allCases {
            for kind in [VoiceOutputSource.typedText, .clipboard, .history] {
                let owner = kind == .history ? UUID() : nil
                let source = try VoiceOutputSourceSnapshot(
                    source: kind, text: "Synthetic cafe\u{301}.", recordID: owner)
                let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: kind, historyRecordID: owner)
                let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                    try await self.synthesize(source, region: region)
                }
                XCTAssertEqual(wav, audio)
                let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
                XCTAssertEqual(request.url, region.speakEndpoint)
                let body = try json(request)
                XCTAssertEqual(body["voice"] as? String, SonioxTTSCatalog.defaultVoiceID)
                XCTAssertEqual(body["model"] as? String, SonioxTTSCatalog.defaultModel.rawValue)
                XCTAssertEqual(body["language"] as? String, "fr")
                XCTAssertEqual(body["audio_format"] as? String, "wav")
                XCTAssertEqual(body["sample_rate"] as? Int, 24_000)
                XCTAssertEqual(body["speed"] as? Double, 1.25)
                XCTAssertEqual(body["text"] as? String, source.text)
                let record = try XCTUnwrap(capture.records.first)
                XCTAssertEqual(record.outcome, .completed)
                XCTAssertEqual(record.historyRecordID, owner)
                XCTAssertEqual(record.audioDuration, Double(pcm.count) / 48_000)
                XCTAssertEqual(record.estimatedCostUSD,
                    Decimal(source.text.count) * SonioxTTSAPI.estimatedCostPerThousandCharacters / 1_000)
            }
        }
    }

    func testSegmentedGraphemes_OneKeyReadOrderedRequestsAndOneCompleteWave() async throws {
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        let source = try VoiceOutputSourceSnapshot(
            source: .typedText, text: "  " + String(repeating: "e\u{301}", count: 5_001) + "  ")
        let chunks = TTSTextChunker.chunks(source.text, maximumCharacters: SonioxTTSAPI.maxTextLength)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 5_000 })
        let probe = SonioxSyntheticKeyProbe()
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        let wav = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await self.synthesize(source, region: .europe, credential: { await probe.read() })
        }
        let reads = await probe.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(wav.count, 44 + pcm.count * chunks.count)
        XCTAssertEqual(try StubURLProtocol.recordedRequests.map { try json($0)["text"] as? String },
                       chunks.map(Optional.some))
        XCTAssertEqual(capture.records.map(\.inputCharacters), chunks.map { $0.unicodeScalars.count })
        XCTAssertTrue(capture.records.allSatisfy { $0.outcome == .completed })
    }

    func testMalformedAndStreamingContainers_RejectWithoutPublishingPartialAudio() async throws {
        var badRate = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        badRate.replaceSubrange(28..<32, with: [0, 0, 0, 0])
        let valid = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        let malformed = [Data(), Data(valid.dropLast(2)), DeepgramSpeechFixture.streamedWAV(pcm: pcm), badRate,
            DeepgramSpeechFixture.canonicalWAV(pcm: pcm, rate: 48_000),
            DeepgramSpeechFixture.canonicalWAV(pcm: pcm, channels: 2),
            DeepgramSpeechFixture.canonicalWAV(pcm: Data(repeating: 0, count: 100))]
        for body in malformed {
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), body) }
            do { _ = try await synthesize(source()); XCTFail("Malformed audio admitted") } catch {
                XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
            }
        }
    }

    func testDeclaredAndAggregateAudioBounds_RejectExactOverLimitResponses() async throws {
        let limit = DeepgramSpeechExport.maximumPCMBytes
        StubURLProtocol.handler = {
            .respond(DeepgramSpeechFixture.response($0, headers: ["Content-Length": "\(limit + 1)"]), Data())
        }
        do { _ = try await synthesize(source()); XCTFail("Over-limit response admitted") } catch {
            XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge)
        }
        let audio = DeepgramSpeechFixture.canonicalWAV(
            pcm: Data(repeating: 1, count: DeepgramSpeechExport.maximumPCMBytes / 2 + 2))
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        do {
            _ = try await synthesize(.init(source: .typedText, text: String(repeating: "x", count: 5_001)))
            XCTFail("Over-limit combined PCM admitted")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .audioTooLarge) }
    }

    func testCompleteContainer_RejectsDuplicateFormatsDataAndMalformedTrailingChunks() async throws {
        let valid = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        var duplicate = valid
        duplicate.insert(contentsOf: valid[12..<36], at: 36)
        let malformed = [
            duplicate, valid + Data([1]),
            valid + Data("JUNK".utf8) + Data([4, 0, 0, 0, 1, 2]),
            valid + Data("data".utf8) + Data([2, 0, 0, 0, 1, 2])
        ]
        for bytes in malformed {
            let body = completeRIFF(bytes)
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), body) }
            do { _ = try await synthesize(source()); XCTFail("Malformed trailing container admitted") } catch {
                XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
            }
        }
        let metadata = completeRIFF(valid + Data("JUNK".utf8) + Data([2, 0, 0, 0, 1, 2]))
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), metadata) }
        let canonical = try await synthesize(source())
        XCTAssertEqual(canonical, valid)
    }

    func testLaterSegmentFailure_RefusesPartialResultAndRetainsMeasuredCompletedRequest() async throws {
        let valid = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: StubURLProtocol.body(of: request)) as? [String: Any])
            let count = (body["text"] as? String)?.count
            return count == 5_000 ? .respond(DeepgramSpeechFixture.response(request), valid) :
                .respond(DeepgramSpeechFixture.response(request, status: 503), Data("synthetic private text".utf8))
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: String(repeating: "x", count: 5_001))
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Partial segmented audio published")
        } catch { XCTAssertEqual(error as? DesktopSonioxSpeechError, .service(503, .unknown("unknown"))) }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        XCTAssertEqual(capture.records.map(\.outcome), [.completed, .failed])
        XCTAssertEqual(capture.records.first?.audioDuration, Double(pcm.count) / 48_000)
        XCTAssertNil(capture.records.last?.audioDuration)
    }

    func testTransportTimeout_IsSanitizedAndBalancesFailedUsageWithoutRegionalRetry() async throws {
        StubURLProtocol.handler = { _ in .fail(URLError(.timedOut)) }
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await self.synthesize(self.source(), region: .europe)
            }
            XCTFail("Timed-out exchange produced audio")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .timedOut) }
        XCTAssertEqual(capture.records.map(\.outcome), [.failed])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.first?.url, SonioxTTSRegion.europe.speakEndpoint)
    }

    func testErrorsAndRedirectStatus_DoNotEchoBodiesOrTryAnotherRegion() async throws {
        let secret = "synthetic-secret-or-transcript"
        let body = try JSONSerialization.data(withJSONObject: [
            "error_type": secret, "error_message": secret, "request_id": secret
        ])
        for status in [302, 401, 403, 429, 503] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = {
                .respond(DeepgramSpeechFixture.response($0, status: status,
                    headers: ["Location": SonioxTTSRegion.unitedStates.speakEndpoint.absoluteString]), body)
            }
            do { _ = try await synthesize(source(), region: .japan); XCTFail("Service error admitted") } catch {
                XCTAssertFalse(error.localizedDescription.contains(secret))
                XCTAssertFalse(String(reflecting: error).contains(secret))
            }
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
            XCTAssertEqual(StubURLProtocol.recordedRequests.first?.url, SonioxTTSRegion.japan.speakEndpoint)
        }
    }

    func testCancellation_StopsPendingExchangeAndBalancesUsageWithoutAudio() async throws {
        let entered = expectation(description: "synthetic Soniox exchange admitted")
        StubURLProtocol.onStartLoading = { entered.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .typedText, historyRecordID: nil)
        let work = Task {
            try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(self.source()) }
        }
        await fulfillment(of: [entered], timeout: 3)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled request completed") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(capture.records.count, 1)
        XCTAssertEqual(capture.records.first?.outcome, .cancelled)
        XCTAssertNil(capture.records.first?.audioDuration)
    }

    private func source() throws -> VoiceOutputSourceSnapshot {
        try .init(source: .typedText, text: "Synthetic Soniox speech.")
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot, region: SonioxTTSRegion = .unitedStates,
        credential: @Sendable () async throws -> String = { "synthetic-key" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first),
            options: VoiceSynthesisOptions(speed: 1.25), accountInventory: nil,
            sonioxRegion: region, language: "fr-FR", credential: credential)
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func completeRIFF(_ bytes: Data) -> Data {
        var bytes = bytes
        let size = UInt32(bytes.count - 8)
        bytes.replaceSubrange(4..<8, with: (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        return bytes
    }
}

private actor SonioxSyntheticKeyProbe {
    private(set) var reads = 0
    func read() -> String { reads += 1; return "synthetic-key" }
}
