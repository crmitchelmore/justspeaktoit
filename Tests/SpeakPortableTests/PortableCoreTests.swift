import Foundation
import XCTest
@testable import SpeakCore

/// These contracts are exercised by the same native Swift module on macOS,
/// Windows and Linux. The portable graph intentionally has no Apple SDKs.
final class PortableCoreTests: XCTestCase {
    func testSharedCatalogueIdentifiersRemainUnique() {
        for catalogue in [ModelCatalog.liveTranscription, ModelCatalog.batchTranscription,
                          ModelCatalog.postProcessing] {
            XCTAssertEqual(Set(catalogue.map(\.id)).count, catalogue.count)
        }
    }

    func testCanonicalCloudCatalogueHasEveryLiveRoute() {
        for model in ModelCatalog.remoteLiveTranscription {
            let route = LiveTranscriptionRouting.route(for: model.id)
            XCTAssertNotNil(route, model.id)
            XCTAssertEqual(route?.modelID, model.id)
            XCTAssertNotNil(route?.apiKeyIdentifier, model.id)
            XCTAssertGreaterThan(route?.sampleRate ?? 0, 0)
        }
    }

    func testRetiredIdentifiersMigrateUsingTheSharedCatalogue() {
        XCTAssertEqual(
            ModelCatalog.normalizedBatchTranscriptionModel("elevenlabs/scribe_v1"),
            ModelCatalog.elevenLabsScribeV2BatchID
        )
        XCTAssertEqual(CartesiaBatchClient.catalogID, BatchTranscriptionModelIdentifiers.cartesiaInkWhisper)
        XCTAssertEqual(GladiaBatchClient.catalogID, BatchTranscriptionModelIdentifiers.gladiaSolaria)
        XCTAssertEqual(SpeechmaticsBatchClient.enhancedCatalogID,
                       BatchTranscriptionModelIdentifiers.speechmaticsEnhanced)
        XCTAssertEqual(MetaMuseVoiceTranscribe.batchCatalogID, "meta/muse-voice-transcribe-1.0")
    }

    func testPortableBuildDoesNotClaimAppleSpeechAvailability() async {
        XCTAssertFalse(AppleLocalModels.supportsSpeechTranscriber)
        XCTAssertFalse(AppleLocalModels.supportsDictationTranscriber)
        XCTAssertFalse(AppleLocalModels.supportsSpeechDetector)
        XCTAssertFalse(AppleLocalModels.supportsFoundationModels)
        do {
            _ = try await AppleFoundationModelPolisher.respond(systemPrompt: "Clean up", userMessage: "Hello")
            XCTFail("An unavailable native model must report failure")
        } catch {
            guard case AppleLocalModelError.foundationModelUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTranscriptRetriesAreDeduplicatedWithoutLosingRepeatedSpeech() {
        var transcript = TranscriptAccumulator(shape: .standaloneSegments)
        transcript.append(final: "Yes.", eventID: "first")
        transcript.append(final: "Yes.", eventID: "first")
        transcript.append(final: "Yes.", eventID: "second")
        XCTAssertEqual(transcript.text, "Yes. Yes.")
        XCTAssertEqual(transcript.display(withInterim: "Again"), "Yes. Yes. Again")
    }

    func testCumulativeTranscriptRevisionsReplaceEarlierWording() {
        var transcript = TranscriptAccumulator(shape: .cumulativeTranscript)
        transcript.append(final: "Call John on Monday")
        transcript.append(final: "Call Joan on Tuesday.")
        XCTAssertEqual(transcript.text, "Call Joan on Tuesday.")
        XCTAssertEqual(transcript.display(withInterim: "Call Joan on Tuesday, please."),
                       "Call Joan on Tuesday, please.")
    }

    func testUnicodeInsertionDiffRoundTripsWithoutSplittingSurrogatePairs() {
        let cases = [
            ("Hello 👩🏽‍💻", "Hello 👩🏽‍💻, welcome!"),
            ("Café on Monday", "Café on Tuesday"),
            ("こんにちは", "こんにちは世界"),
            ("a👨‍👩‍👧‍👦z", "a👩‍👩‍👦z")
        ]
        for (before, after) in cases {
            let change = StreamingTextReconciler.diff(from: before, to: after)
            XCTAssertEqual(StreamingTextReconciler.apply(change, to: before), after)
        }
    }

    @MainActor
    func testCancelledStartupCannotActivateOrReplaceANewerSession() async throws {
        let lifecycle = RecordingLifecycleCoordinator()
        let oldRun = try XCTUnwrap(lifecycle.beginStart())
        var cancellations = 0
        lifecycle.installStartCancellation(for: oldRun) { cancellations += 1 }
        lifecycle.retireStartRun()
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(lifecycle.activate(oldRun))
        XCTAssertNil(lifecycle.beginStart(), "Resources remain owned until unwind finishes")
        lifecycle.finishStartUnwind()
        let newRun = try XCTUnwrap(lifecycle.beginStart())
        XCTAssertFalse(lifecycle.activate(oldRun))
        XCTAssertTrue(lifecycle.activate(newRun))
        XCTAssertEqual(lifecycle.state, .recording)
    }

    func testAudioPrerollBoundRetainsTheMostRecentContiguousFrames() {
        let buffer = StreamingAudioPreroll(sampleRate: 10, seconds: 1, bytesPerFrame: 2)
        let chunks = [Data(repeating: 1, count: 8), Data(repeating: 2, count: 8), Data(repeating: 3, count: 8)]
        chunks.forEach(buffer.append)
        XCTAssertEqual(buffer.snapshot.byteCount, 16)
        XCTAssertEqual(buffer.snapshot.droppedChunkCount, 1)
        XCTAssertEqual(buffer.drain(), Array(chunks.suffix(2)))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPCMConversionIsClampedLittleEndianAndWavePayloadIsPreserved() throws {
        let samples: [Float] = [-2, -1, 0, 1, 2]
        let pcm = samples.withUnsafeBufferPointer {
            PCM16Converter.data(from: $0.baseAddress!, frameCount: $0.count)
        }
        XCTAssertEqual(Array(pcm), [1, 128, 1, 128, 0, 0, 255, 127, 255, 127])
        let wave = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        XCTAssertEqual(String(data: wave.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: wave[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(wave.suffix(pcm.count), pcm)
        XCTAssertEqual(wave.count, 44 + pcm.count)
        XCTAssertNil(PCMWaveWriter.wavData(pcm: pcm, sampleRate: -1))
    }

    func testFoundationNumericBridgingPreservesBooleanIntegerAndFloatTypes() throws {
        XCTAssertEqual(try AnyCodable(NSNumber(value: true)).storage, .bool(true))
        XCTAssertEqual(try AnyCodable(NSNumber(value: false)).storage, .bool(false))
        XCTAssertEqual(try AnyCodable(NSNumber(value: Int8(0))).storage, .int(0))
        XCTAssertEqual(try AnyCodable(NSNumber(value: Int8(1))).storage, .int(1))
        XCTAssertEqual(try AnyCodable(NSNumber(value: Int8(-1))).storage, .int(-1))
        XCTAssertEqual(try AnyCodable(NSNumber(value: 42)).storage, .int(42))
        XCTAssertEqual(try AnyCodable(NSNumber(value: 2.5)).storage, .double(2.5))
        let payload = try JSONSerialization.jsonObject(with: Data("{\"enabled\":true,\"count\":42}".utf8))
        let wrapped = try AnyCodable(payload)
        XCTAssertEqual(wrapped.storage, .object(["enabled": .bool(true), "count": .int(42)]))
    }

    func testSilentTranscriptsNeverReportSuccessfulDelivery() {
        XCTAssertEqual(TranscriptionCompletionOutcome.unconfirmed(transcript: " \n\t"), .noSpeech)
        XCTAssertEqual(TranscriptionCompletionOutcome.unconfirmed(transcript: "Hello"), .ready)
    }

    func testHistorySearchUsesCanonicalFriendlyModelNames() {
        let entry = HistoryPresentationItem(
            id: UUID(), createdAt: Date(), rawTranscription: "hello", processedTranscription: "Hello.",
            modelIdentifiers: [ParakeetLocalModels.tdtV3Int8SourceID], recordingDuration: 2,
            originPlatform: "windows"
        )
        XCTAssertTrue(HistorySearchQuery(searchText: "Parakeet").matches(entry))
        XCTAssertFalse(HistorySearchQuery(includeErrorsOnly: true).matches(entry))
        XCTAssertEqual(HistoryPresentationStatistics(items: [entry]).totalWords, 1)
    }
}
