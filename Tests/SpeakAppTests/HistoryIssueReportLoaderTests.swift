import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class HistoryIssueReportLoaderTests: XCTestCase {
    func testCancelledRecordingWithoutAudioProducesReadyPreview() async throws {
        let item = Self.cancelledRecording()
        let loader = HistoryIssueReportLoader(item: item)
        loader.start()
        try await waitUntil { !loader.isLoading }
        guard case .ready(let controller) = loader.phase else {
            return XCTFail("Expected ready preview, got \(loader.phase)")
        }
        XCTAssertEqual(controller.report.jsonData, HistoryIssueReporter.report(for: item).jsonData)
        XCTAssertFalse(controller.report.body.isEmpty)
        controller.setIncludesDiagnostics(false)
        XCTAssertEqual(
            controller.report.jsonData,
            HistoryIssueReporter.report(for: item, includeDiagnostics: false).jsonData
        )
    }

    func testStartReturnsImmediatelyWhileGenerationRunsOffMainActor() async throws {
        let gate = DispatchSemaphore(value: 0)
        let ranOnMain = LockedFlag()
        let loader = makeLoader(timeout: .seconds(30)) { item in
            ranOnMain.set(Thread.isMainThread)
            _ = gate.wait(timeout: .now() + 10)
            return HistoryIssueReportLoader.liveGenerate(item)
        }
        loader.start()
        // Main actor is free while generation is blocked.
        XCTAssertTrue(loader.isLoading)
        await Task.yield()
        XCTAssertTrue(loader.isLoading)
        gate.signal()
        try await waitUntil { !loader.isLoading }
        guard case .ready = loader.phase else { return XCTFail("Expected ready, got \(loader.phase)") }
        XCTAssertFalse(ranOnMain.value)
    }

    func testStalledGenerationTimesOutAndLateResultIsIgnored() async throws {
        let gate = DispatchSemaphore(value: 0)
        let loader = makeLoader(timeout: .milliseconds(50)) { item in
            _ = gate.wait(timeout: .now() + 10)
            return HistoryIssueReportLoader.liveGenerate(item)
        }
        loader.start()
        try await waitUntil { !loader.isLoading }
        guard case .timedOut = loader.phase else { return XCTFail("Expected timeout, got \(loader.phase)") }
        gate.signal()
        try await Task.sleep(for: .milliseconds(200))
        guard case .timedOut = loader.phase else { return XCTFail("Late result replaced timeout") }
    }

    func testCancelBeforeCompletionNeverPresentsPreview() async throws {
        let gate = DispatchSemaphore(value: 0)
        let loader = makeLoader(timeout: .seconds(30)) { item in
            _ = gate.wait(timeout: .now() + 10)
            return HistoryIssueReportLoader.liveGenerate(item)
        }
        loader.start()
        loader.cancel()
        gate.signal()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(loader.isLoading)
    }

    private func makeLoader(
        timeout: Duration, generate: @escaping HistoryIssueReportLoader.Generate
    ) -> HistoryIssueReportLoader {
        HistoryIssueReportLoader(item: Self.cancelledRecording(), timeout: timeout, generate: generate) {
            HistoryIssueReportController(report: $0.full, reportWithoutDetails: $0.withoutDetails)
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Condition not met in time", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func cancelledRecording() -> HistoryItem {
        let date = Date(timeIntervalSince1970: 1_717_171_717)
        return HistoryItem(
            createdAt: date, updatedAt: date, modelsUsed: [],
            rawTranscription: nil, postProcessedTranscription: nil, recordingDuration: 0,
            cost: nil, audioFileURL: nil, networkExchanges: [], events: [],
            phaseTimestamps: PhaseTimestamps(
                recordingStarted: date, recordingEnded: date, transcriptionStarted: nil,
                transcriptionEnded: nil, postProcessingStarted: nil, postProcessingEnded: nil,
                outputDelivered: nil
            ),
            trigger: HistoryTrigger(
                gesture: .doubleTap, hotKeyDescription: "Fn", outputMethod: .none, destinationApplication: nil
            ),
            personalCorrections: nil,
            errors: [HistoryError(phase: .recording, message: "Cancelled by user (Escape)", debugDescription: nil)]
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}
