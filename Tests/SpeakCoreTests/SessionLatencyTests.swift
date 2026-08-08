import Foundation
import XCTest
@testable import SpeakCore

final class SessionLatencyMetricsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func metrics(
        hotKey: TimeInterval? = nil,
        capture: TimeInterval? = nil,
        firstPartial: TimeInterval? = nil,
        firstInsert: TimeInterval? = nil,
        stop: TimeInterval? = nil,
        final: TimeInterval? = nil
    ) -> SessionLatencyMetrics {
        SessionLatencyMetrics(
            hotKeyPressedAt: hotKey.map { self.base.addingTimeInterval($0) },
            captureStartedAt: capture.map { self.base.addingTimeInterval($0) },
            firstPartialAt: firstPartial.map { self.base.addingTimeInterval($0) },
            firstInsertAt: firstInsert.map { self.base.addingTimeInterval($0) },
            stopPressedAt: stop.map { self.base.addingTimeInterval($0) },
            finalInsertAt: final.map { self.base.addingTimeInterval($0) }
        )
    }

    func testDerivedIntervals_ComputeMillisecondsBetweenCheckpoints() {
        let metrics = self.metrics(
            hotKey: 0, capture: 0.08, firstPartial: 0.58, firstInsert: 0.73, stop: 5, final: 5.9
        )
        XCTAssertEqual(metrics.captureStartMs, 80)
        XCTAssertEqual(metrics.firstPartialMs, 500)
        XCTAssertEqual(metrics.firstInsertMs, 650)
        XCTAssertEqual(metrics.stopToFinalMs, 900)
        XCTAssertTrue(metrics.hasAnyInterval)
    }

    func testDerivedIntervals_NilWhenEitherEndpointMissing() {
        XCTAssertNil(self.metrics(hotKey: 0).captureStartMs)
        XCTAssertNil(self.metrics(capture: 1).captureStartMs)
        XCTAssertNil(self.metrics(firstPartial: 1).firstPartialMs)
        XCTAssertNil(self.metrics(stop: 1).stopToFinalMs)
        XCTAssertFalse(self.metrics().hasAnyInterval)
    }

    func testDerivedIntervals_NilWhenClockRanBackwards() {
        let metrics = self.metrics(hotKey: 2, capture: 1)
        XCTAssertNil(metrics.captureStartMs)
        XCTAssertFalse(metrics.hasAnyInterval)
    }

    func testMilliseconds_RoundsToNearestWholeMillisecond() {
        let start = self.base
        XCTAssertEqual(
            SessionLatencyMetrics.milliseconds(from: start, to: start.addingTimeInterval(0.0004)), 0
        )
        XCTAssertEqual(
            SessionLatencyMetrics.milliseconds(from: start, to: start.addingTimeInterval(0.0006)), 1
        )
        XCTAssertEqual(SessionLatencyMetrics.milliseconds(from: start, to: start), 0)
        XCTAssertNil(SessionLatencyMetrics.milliseconds(from: nil, to: start))
        XCTAssertNil(SessionLatencyMetrics.milliseconds(from: start, to: nil))
    }

    func testFormattedMilliseconds_UsesMsBelowOneSecondAndSecondsAbove() {
        XCTAssertEqual(SessionLatencyMetrics.formattedMilliseconds(0), "0 ms")
        XCTAssertEqual(SessionLatencyMetrics.formattedMilliseconds(999), "999 ms")
        XCTAssertEqual(SessionLatencyMetrics.formattedMilliseconds(1000), "1.0 s")
        XCTAssertEqual(SessionLatencyMetrics.formattedMilliseconds(1440), "1.4 s")
        XCTAssertEqual(SessionLatencyMetrics.formattedMilliseconds(12_345), "12.3 s")
    }

    func testCodable_RoundTripsMillisecondPrecision() throws {
        // Persisted as integer milliseconds so the whole-second ISO-8601 date
        // strategy used by history persistence cannot destroy sub-second data.
        let original = self.metrics(hotKey: 0, capture: 0.1, firstPartial: 0.4, stop: 3, final: 3.5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionLatencyMetrics.self, from: encoder.encode(original)
        )
        XCTAssertEqual(decoded.captureStartMs, 100)
        XCTAssertEqual(decoded.firstPartialMs, 300)
        XCTAssertEqual(decoded.stopToFinalMs, 500)
        XCTAssertNil(decoded.firstInsertMs)
    }

    func testCodable_DecodesEmptyObjectAsAllNil() throws {
        let decoded = try JSONDecoder().decode(
            SessionLatencyMetrics.self, from: Data("{}".utf8)
        )
        XCTAssertNil(decoded.captureStartMs)
        XCTAssertNil(decoded.stopToFinalMs)
        XCTAssertFalse(decoded.hasAnyInterval)
    }
}

final class LatencyPercentilesTests: XCTestCase {
    func testPercentile_EmptyInputReturnsNil() {
        XCTAssertNil(LatencyPercentiles.percentile(50, of: []))
        XCTAssertNil(LatencyPercentiles.p50(of: []))
        XCTAssertNil(LatencyPercentiles.p95(of: []))
    }

    func testPercentile_SingleValueReturnsThatValueForAnyPercentile() {
        XCTAssertEqual(LatencyPercentiles.percentile(0, of: [42]), 42)
        XCTAssertEqual(LatencyPercentiles.percentile(50, of: [42]), 42)
        XCTAssertEqual(LatencyPercentiles.percentile(95, of: [42]), 42)
        XCTAssertEqual(LatencyPercentiles.percentile(100, of: [42]), 42)
    }

    func testPercentile_NearestRankOnKnownDistribution() {
        // Nearest-rank on 1...10: p50 → 5th value, p95 → ceil(9.5) = 10th value.
        let values = Array(1...10)
        XCTAssertEqual(LatencyPercentiles.p50(of: values), 5)
        XCTAssertEqual(LatencyPercentiles.p95(of: values), 10)
        XCTAssertEqual(LatencyPercentiles.percentile(0, of: values), 1)
        XCTAssertEqual(LatencyPercentiles.percentile(100, of: values), 10)
        XCTAssertEqual(LatencyPercentiles.percentile(10, of: values), 1)
        XCTAssertEqual(LatencyPercentiles.percentile(11, of: values), 2)
    }

    func testPercentile_UnsortedInputIsSortedFirst() {
        let values = [900, 100, 500, 300, 700]
        XCTAssertEqual(LatencyPercentiles.p50(of: values), 500)
        XCTAssertEqual(LatencyPercentiles.p95(of: values), 900)
    }

    func testPercentile_DuplicatesAndLargeSets() {
        let values = Array(repeating: 250, count: 100)
        XCTAssertEqual(LatencyPercentiles.p50(of: values), 250)
        XCTAssertEqual(LatencyPercentiles.p95(of: values), 250)

        let spread = Array(1...100)
        XCTAssertEqual(LatencyPercentiles.p50(of: spread), 50)
        XCTAssertEqual(LatencyPercentiles.p95(of: spread), 95)
    }

    func testPercentile_OutOfRangePercentilesAreClamped() {
        let values = [10, 20, 30]
        XCTAssertEqual(LatencyPercentiles.percentile(-5, of: values), 10)
        XCTAssertEqual(LatencyPercentiles.percentile(150, of: values), 30)
    }
}
