import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

final class HistoryItemLatencyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeItem(
        modelUsages: [ModelUsage] = [],
        latency: SessionLatencyMetrics? = nil
    ) -> HistoryItem {
        HistoryItem(
            modelsUsed: modelUsages.map(\.modelIdentifier),
            modelUsages: modelUsages,
            rawTranscription: "hello",
            postProcessedTranscription: nil,
            recordingDuration: 4,
            cost: nil,
            audioFileURL: nil,
            networkExchanges: [],
            events: [],
            phaseTimestamps: PhaseTimestamps(
                recordingStarted: self.base,
                recordingEnded: nil,
                transcriptionStarted: nil,
                transcriptionEnded: nil,
                postProcessingStarted: nil,
                postProcessingEnded: nil,
                outputDelivered: nil
            ),
            trigger: HistoryTrigger(
                gesture: .hold,
                hotKeyDescription: "Fn",
                outputMethod: .accessibility,
                destinationApplication: "Notes"
            ),
            personalCorrections: nil,
            errors: [],
            latency: latency
        )
    }

    private func makeLatency(
        firstPartialMs: Int? = nil,
        firstInsertMs: Int? = nil,
        stopToFinalMs: Int? = nil,
        captureStartMs: Int? = nil
    ) -> SessionLatencyMetrics {
        let hotKey = self.base
        let capture = captureStartMs.map { hotKey.addingTimeInterval(Double($0) / 1000) }
            ?? hotKey.addingTimeInterval(0.05)
        let stop = capture.addingTimeInterval(5)
        return SessionLatencyMetrics(
            hotKeyPressedAt: captureStartMs != nil ? hotKey : nil,
            captureStartedAt: capture,
            firstPartialAt: firstPartialMs.map { capture.addingTimeInterval(Double($0) / 1000) },
            firstInsertAt: firstInsertMs.map { capture.addingTimeInterval(Double($0) / 1000) },
            stopPressedAt: stop,
            finalInsertAt: stopToFinalMs.map { stop.addingTimeInterval(Double($0) / 1000) }
        )
    }

    private func streamingItem(
        provider: String = "deepgram/nova-3",
        firstPartialMs: Int,
        firstInsertMs: Int,
        stopToFinalMs: Int? = nil
    ) -> HistoryItem {
        self.makeItem(
            modelUsages: [ModelUsage(modelIdentifier: provider, phase: .transcriptionLive)],
            latency: self.makeLatency(
                firstPartialMs: firstPartialMs,
                firstInsertMs: firstInsertMs,
                stopToFinalMs: stopToFinalMs
            )
        )
    }

    /// A one-shot (transcribe-then-paste) session: no partials, and the first
    /// visible character is the final paste.
    private func oneShotItem(
        provider: String = "openai/whisper-1",
        firstInsertMs: Int,
        stopToFinalMs: Int? = nil
    ) -> HistoryItem {
        self.makeItem(
            modelUsages: [ModelUsage(modelIdentifier: provider, phase: .transcriptionBatch)],
            latency: self.makeLatency(firstInsertMs: firstInsertMs, stopToFinalMs: stopToFinalMs)
        )
    }

    // MARK: - Codable compatibility

    func testDecode_LegacyItemWithoutLatencyField_DecodesWithNilLatency() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Items encoded before the latency field existed have no "latency" key —
        // exactly what encoding a nil-latency item produces with synthesized Codable.
        let legacyData = try encoder.encode(self.makeItem(latency: nil))
        let json = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        XCTAssertFalse(json.contains("\"latency\""))

        let decoded = try decoder.decode(HistoryItem.self, from: legacyData)
        XCTAssertNil(decoded.latency)
        XCTAssertEqual(decoded.rawTranscription, "hello")
    }

    func testCodable_RoundTripsLatencyMetrics() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let item = self.makeItem(
            latency: self.makeLatency(firstPartialMs: 480, stopToFinalMs: 950, captureStartMs: 60)
        )
        let decoded = try decoder.decode(HistoryItem.self, from: encoder.encode(item))
        XCTAssertEqual(decoded.latency?.captureStartMs, 60)
        XCTAssertEqual(decoded.latency?.firstPartialMs, 480)
        XCTAssertEqual(decoded.latency?.stopToFinalMs, 950)
    }

    // MARK: - Provider aggregation

    func testTranscriptionProviderID_DerivedFromTranscriptionUsageNotPostProcessing() {
        let item = self.makeItem(modelUsages: [
            ModelUsage(modelIdentifier: "openai/gpt-5-mini", phase: .postProcessing),
            ModelUsage(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive)
        ])
        XCTAssertEqual(item.transcriptionProviderID, "deepgram")
    }

    func testLatencyInsightsByProvider_GroupsAndComputesPercentiles() {
        let deepgramSamples = [300, 400, 500, 600, 700]
        var items = deepgramSamples.map { sample in
            self.makeItem(
                modelUsages: [ModelUsage(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive)],
                latency: self.makeLatency(firstPartialMs: sample, stopToFinalMs: sample + 100)
            )
        }
        items.append(
            self.makeItem(
                modelUsages: [ModelUsage(modelIdentifier: "apple/local/SFSpeechRecognizer", phase: .transcriptionLive)],
                latency: self.makeLatency(firstPartialMs: 200)
            )
        )
        // Item without latency metrics must be ignored.
        items.append(
            self.makeItem(
                modelUsages: [ModelUsage(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive)]
            )
        )

        let insights = items.latencyInsightsByProvider()
        XCTAssertEqual(insights.count, 2)

        let deepgram = insights.first { $0.id == "deepgram" }
        XCTAssertEqual(deepgram?.sessionCount, 5)
        XCTAssertEqual(deepgram?.firstPartial.p50, 500)
        XCTAssertEqual(deepgram?.firstPartial.p95, 700)
        XCTAssertEqual(deepgram?.stopToFinal.p50, 600)
        XCTAssertEqual(deepgram?.stopToFinal.p95, 800)

        let apple = insights.first { $0.id == "apple" }
        XCTAssertEqual(apple?.sessionCount, 1)
        XCTAssertEqual(apple?.firstPartial.p50, 200)
        XCTAssertNil(apple?.stopToFinal.p50)
    }

    // MARK: - Insertion latency (issue #611)

    func testLatencyInsightsByProvider_AggregatesFirstInsertForStreamingSessions() {
        let items = [350, 450, 550, 650, 750].map { insert in
            self.streamingItem(firstPartialMs: insert - 50, firstInsertMs: insert, stopToFinalMs: 900)
        }

        let deepgram = items.latencyInsightsByProvider().first { $0.id == "deepgram" }
        XCTAssertEqual(deepgram?.sessionCount, 5)
        XCTAssertEqual(deepgram?.firstInsert, LatencyDistribution(samples: [350, 450, 550, 650, 750]))
        XCTAssertEqual(deepgram?.firstInsert.sampleCount, 5)
        XCTAssertEqual(deepgram?.firstInsert.p50, 550)
        XCTAssertEqual(deepgram?.firstInsert.p95, 750)
        XCTAssertEqual(deepgram?.firstPartial.sampleCount, 5)
        XCTAssertEqual(deepgram?.stopToFinal.sampleCount, 5)
    }

    func testLatencyInsightsByProvider_AggregatesFirstInsertForOneShotFallbackSessions() {
        let items = [
            self.oneShotItem(firstInsertMs: 900, stopToFinalMs: 850),
            self.oneShotItem(firstInsertMs: 1100, stopToFinalMs: 1050)
        ]

        let openai = items.latencyInsightsByProvider().first { $0.id == "openai" }
        XCTAssertEqual(openai?.sessionCount, 2)
        XCTAssertEqual(openai?.firstPartial.sampleCount, 0, "One-shot sessions have no partials")
        XCTAssertNil(openai?.firstPartial.p50)
        XCTAssertEqual(openai?.firstInsert.sampleCount, 2)
        XCTAssertEqual(openai?.firstInsert.p50, 900)
        XCTAssertEqual(openai?.firstInsert.p95, 1100)
        XCTAssertEqual(openai?.stopToFinal.p50, 850)
    }

    func testLatencyInsightsByProvider_SampleCountsExcludeSessionsMissingThatInterval() {
        let items = [
            self.streamingItem(firstPartialMs: 300, firstInsertMs: 400),
            // Streamed partials but never inserted (clipboard-only session).
            self.makeItem(
                modelUsages: [ModelUsage(modelIdentifier: "deepgram/nova-3", phase: .transcriptionLive)],
                latency: self.makeLatency(firstPartialMs: 320)
            ),
            // Inserted at the end but stop-to-final unknown.
            self.streamingItem(firstPartialMs: 280, firstInsertMs: 2000)
        ]

        let deepgram = items.latencyInsightsByProvider().first { $0.id == "deepgram" }
        XCTAssertEqual(deepgram?.sessionCount, 3)
        XCTAssertEqual(deepgram?.firstPartial.sampleCount, 3)
        XCTAssertEqual(deepgram?.firstInsert.sampleCount, 2)
        XCTAssertEqual(deepgram?.firstInsert.p50, 400)
        XCTAssertEqual(deepgram?.firstInsert.p95, 2000)
        XCTAssertEqual(deepgram?.stopToFinal.sampleCount, 0)
    }

    func testLatencyInsightsByProvider_KeepsStreamingAndOneShotProvidersSeparate() {
        let items = [
            self.streamingItem(firstPartialMs: 300, firstInsertMs: 400),
            self.oneShotItem(firstInsertMs: 1200)
        ]

        let insights = items.latencyInsightsByProvider()
        XCTAssertEqual(Set(insights.map(\.id)), ["deepgram", "openai"])
        XCTAssertEqual(insights.first { $0.id == "deepgram" }?.firstInsert.p50, 400)
        XCTAssertEqual(insights.first { $0.id == "openai" }?.firstInsert.p50, 1200)
    }

    func testLatencyDistribution_EmptySamplesHaveNoPercentiles() {
        let distribution = LatencyDistribution(samples: [])
        XCTAssertEqual(distribution.sampleCount, 0)
        XCTAssertNil(distribution.p50)
        XCTAssertNil(distribution.p95)
    }

    func testLatencyOverview_UsesCaptureStartSamplesOnly() {
        let items = [
            self.makeItem(latency: self.makeLatency(captureStartMs: 40)),
            self.makeItem(latency: self.makeLatency(captureStartMs: 80)),
            self.makeItem(latency: self.makeLatency(firstPartialMs: 300)),
            self.makeItem()
        ]
        let overview = items.latencyOverview()
        XCTAssertEqual(overview.sessionCount, 2)
        XCTAssertEqual(overview.captureStartP50, 40)
        XCTAssertEqual(overview.captureStartP95, 80)
    }

    func testLatencyOverview_EmptyHistoryHasNoSamples() {
        let overview = [HistoryItem]().latencyOverview()
        XCTAssertEqual(overview.sessionCount, 0)
        XCTAssertNil(overview.captureStartP50)
        XCTAssertNil(overview.captureStartP95)
    }
}
