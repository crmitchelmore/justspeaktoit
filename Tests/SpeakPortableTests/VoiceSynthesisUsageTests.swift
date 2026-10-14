import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class VoiceSynthesisUsageTests: DeepgramSpeechStubTestCase {
    func testCanonicalPrices_KeepBothMAIModelsAndFluxUnknown() throws {
        for voice in AzureMAIVoiceCatalog.voices {
            let desktop = DesktopSpeechVoice.azureMAI(voice)
            XCTAssertEqual(VoiceSynthesisPricing.estimate(for: desktop, characterCount: 1_000_000),
                           voice.model == .voice21 ? Decimal(22) : Decimal(15))
        }
        XCTAssertEqual(VoiceSynthesisPricing.estimate(
            for: .azureNeural(AzureNeuralVoiceCatalog.voices[0]), characterCount: 1_000_000), Decimal(16))
        XCTAssertNil(VoiceSynthesisPricing.estimate(
            for: .deepgram(DeepgramSpeechCatalog.fluxVoices[0]), characterCount: 100))
        XCTAssertNil(VoiceSynthesisPricing.estimate(
            for: .azureMAI(AzureMAIVoiceCatalog.voices[0]), characterCount: -1))
    }

    func testActualAzureRequests_AccountSegmentInputsAndValidatedAudioWithoutTextOrTokens() async throws {
        let wav = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
        let source = try VoiceOutputSourceSnapshot(
            source: .clipboard, text: String(repeating: "Synthetic private e\u{301} input. ", count: 130))
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .clipboard, historyRecordID: UUID())
        _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
        let segments = SpeechTextSegmenter.segments(source.text)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(capture.records.count, StubURLProtocol.recordedRequests.count)
        XCTAssertEqual(capture.records.map(\.inputCharacters), segments.map { $0.unicodeScalars.count })
        XCTAssertTrue(capture.records.allSatisfy { $0.outcome == .completed && $0.historyRecordID == nil })
        XCTAssertTrue(capture.records.allSatisfy { $0.audioDuration == Double(pcm.count) / 48_000 })
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(capture.records), encoding: .utf8))
        XCTAssertFalse(json.contains("Synthetic private"))
        XCTAssertFalse(json.contains("synthetic-key"))
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.lowercased().contains("billed"))
    }

    func testFailuresAndPreRequestRefusal_DoNotInventValidatedAudio() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic failure.")
        let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .typedText, historyRecordID: nil)
        StubURLProtocol.handler = {
            .respond(DeepgramSpeechFixture.response($0, status: 503), Data("private synthetic error".utf8))
        }
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(capture) { try await self.synthesize(source) }
            XCTFail("Failure returned audio")
        } catch { XCTAssertTrue(error is AzureSpeechError) }
        XCTAssertEqual(capture.records.count, 1)
        XCTAssertEqual(capture.records.first?.outcome, .failed)
        XCTAssertNil(capture.records.first?.audioDuration)
        let refused = VoiceSynthesisUsage.Capture(operation: .read, source: .history, historyRecordID: UUID())
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(refused) {
                try await self.synthesize(source, credential: { "" })
            }
            XCTFail("Missing credential admitted a request")
        } catch { XCTAssertTrue(refused.records.isEmpty) }
    }

    func testDeepgramReadBoundary_UsesPronouncedInputAndTrueHistoryOwner() async throws {
        let wav = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
        let owner = UUID()
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .history, historyRecordID: owner)
        let request = try DeepgramSpeechRequest(
            text: "  Synthetic pronunciation.  ", voice: DeepgramSpeechCatalog.voices[0])
        let synthesizer = DeepgramSpeechSynthesizer(session: session)
        let utterance = try XCTUnwrap(synthesizer.utterance(for: request))
        _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
            try await synthesizer.synthesize(utterance, apiKey: "synthetic-key")
        }
        XCTAssertEqual(capture.records.first?.inputCharacters, utterance.characterCount)
        XCTAssertEqual(capture.records.first?.historyRecordID, owner)
        XCTAssertEqual(capture.records.first?.outcome, .completed)
    }

    func testCancelledTransportAndInvalidAudio_KeepRequestsButNeverInventDuration() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic cancellation.")
        let cancelled = VoiceSynthesisUsage.Capture(operation: .generate, source: .textFile, historyRecordID: nil)
        StubURLProtocol.handler = { _ in .fail(URLError(.cancelled)) }
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(cancelled) { try await self.synthesize(source) }
            XCTFail("Cancelled synthesis returned audio")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelled.records.first?.outcome, .cancelled)
        XCTAssertNil(cancelled.records.first?.audioDuration)
        let invalid = VoiceSynthesisUsage.Capture(operation: .generate, source: .textFile, historyRecordID: nil)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), Data("not audio".utf8)) }
        do {
            _ = try await VoiceSynthesisUsage.$capture.withValue(invalid) { try await self.synthesize(source) }
            XCTFail("Invalid audio was accepted")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio) }
        XCTAssertEqual(invalid.records.first?.outcome, .failed)
        XCTAssertNil(invalid.records.first?.audioDuration)
    }

    private func synthesize(
        _ source: VoiceOutputSourceSnapshot,
        credential: @Sendable () async throws -> String = { "synthetic-key:eastus" }
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: .azureMAI(AzureMAIVoiceCatalog.voices[0]),
            options: VoiceSynthesisOptions(), credential: credential
        )
    }
}
