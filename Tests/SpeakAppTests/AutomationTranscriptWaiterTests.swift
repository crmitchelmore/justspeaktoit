#if os(macOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class AutomationTranscriptWaiterTests: XCTestCase {
    private var root: URL!
    private var history: HistoryManager!

    override func setUp() async throws {
        try await super.setUp()
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.history = HistoryManager(fileManager: AwaitHistoryFileManager(root: self.root),
                                      flushInterval: 3_600, batchSizeThreshold: 10_000)
        await self.history.waitUntilLoaded()
    }

    override func tearDown() async throws {
        await self.history.flushImmediately()
        self.history = nil
        try? FileManager.default.removeItem(at: self.root)
        try await super.tearDown()
    }

    private func item(_ id: UUID = UUID(), text: String = "raw", processed: String? = nil) -> HistoryItem {
        HistoryItem(id: id, createdAt: Date(), modelsUsed: ["local/fixture"], rawTranscription: text,
                    postProcessedTranscription: processed, recordingDuration: 1, cost: nil, audioFileURL: nil,
                    networkExchanges: [], events: [], phaseTimestamps: .init(recordingStarted: nil, recordingEnded: nil,
                        transcriptionStarted: nil,
                        transcriptionEnded: nil, postProcessingStarted: nil, postProcessingEnded: nil,
                        outputDelivered: nil),
                    trigger: .init(gesture: .uiButton, hotKeyDescription: "fixture", outputMethod: .clipboard,
                                   destinationApplication: nil),
                    personalCorrections: nil, errors: [])
    }

    private func request(_ capture: UUID, since: UUID? = nil) -> AutomationRequest {
        AutomationRequest(command: .awaitTranscript, captureID: capture.uuidString, sinceID: since?.uuidString)
    }

    private func value(_ task: Task<AutomationResult, Error>) async throws -> AutomationResult {
        let settled = expectation(description: "waiter settled within fixture bound")
        var outcome: Result<AutomationResult, Error>?
        Task { @MainActor in outcome = await task.result; settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        guard let outcome else {
            task.cancel()
            throw AutomationError(code: .timedOut, message: "Fixture did not settle; owned wait cancelled.")
        }
        return try outcome.get()
    }

    func testExactLocalCompletion_FreezesProjectionAndPreservesSyncCallback() async throws {
        let capture = UUID()
        let baseline = self.item()
        await self.history.append(baseline)
        var syncCalls = 0
        self.history.onItemAppended = { _ in syncCalls += 1 }
        let waiter = AutomationTranscriptWaiter(history: self.history) { capture }
        let installed = expectation(description: "observer registered")
        waiter.didSubscribe = { installed.fulfill() }
        let pending = Task { try await waiter.wait(for: self.request(capture, since: baseline.id)) }
        await fulfillment(of: [installed], timeout: 2)
        // Import/sync append, unrelated local completion and edits cannot qualify.
        let unrelated = self.item()
        await self.history.append(unrelated)
        self.history.finishAutomationCapture(id: unrelated.id, item: unrelated)
        await self.history.update(self.item(baseline.id, text: "edited baseline"))
        let resultItem = self.item(capture, processed: "frozen processed")
        await self.history.append(resultItem)
        self.history.finishAutomationCapture(id: capture, item: resultItem)
        let result = try await self.value(pending)
        await self.history.update(self.item(capture, processed: "later polish"))
        XCTAssertEqual(result.text, "frozen processed")
        XCTAssertEqual(result.entry?.id, capture.uuidString)
        XCTAssertEqual(result.captureID, capture.uuidString)
        XCTAssertEqual(syncCalls, 2)
    }

    func testPreexistingRow_IsRejectedEvenWhileCaptureStillActive() async {
        let capture = UUID()
        await self.history.append(self.item(capture))
        let waiter = AutomationTranscriptWaiter(history: self.history) { capture }
        do {
            _ = try await waiter.wait(for: self.request(capture))
            XCTFail("Already appended rows must never replay as a new capture")

        } catch {
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument) }
    }

    func testUnknownDeletedCursorAndDifferentCapture_AreRejected() async {
        let capture = UUID()
        let waiter = AutomationTranscriptWaiter(history: self.history) { capture }
        for request in [self.request(capture, since: UUID()), self.request(UUID())] {
            do {
                _ = try await waiter.wait(for: request)
                XCTFail("Invalid identity accepted")
        } catch {
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument) }
        }
    }

    func testFailedPostprocessingOrCancelledCapture_NeverReturnsSalvagedRowOrNextCapture() async {
        let capture = UUID()
        let waiter = AutomationTranscriptWaiter(history: self.history) { capture }
        let installed = expectation(description: "registered")
        waiter.didSubscribe = { installed.fulfill() }
        let pending = Task { try await waiter.wait(for: self.request(capture)) }
        await fulfillment(of: [installed], timeout: 2)
        await self.history.append(self.item(capture, text: "salvaged raw"))
        self.history.finishAutomationCapture(id: capture, item: nil)
        do { _ = try await self.value(pending); XCTFail("Failed capture succeeded")
        } catch {
            XCTAssertEqual((error as? AutomationError)?.code, .transcriptionFailed) }
        let other = self.item()
        await self.history.append(other)
        self.history.finishAutomationCapture(id: other.id, item: other)
    }

    func testSilentCapture_FailsAndCancellationRemovesSubscription() async {
        let capture = UUID()
        let waiter = AutomationTranscriptWaiter(history: self.history) { capture }
        let installed = expectation(description: "registered")
        waiter.didSubscribe = { installed.fulfill() }
        let pending = Task { try await waiter.wait(for: self.request(capture)) }
        await fulfillment(of: [installed], timeout: 2)
        let silent = self.item(capture, text: " \n ")
        await self.history.append(silent)
        self.history.finishAutomationCapture(id: capture, item: silent)
        do { _ = try await self.value(pending); XCTFail("Silent result succeeded")
        } catch {
            XCTAssertEqual((error as? AutomationError)?.code, .transcriptionFailed) }

        let nextCapture = UUID()
        let next = AutomationTranscriptWaiter(history: self.history) { nextCapture }
        let subscribed = expectation(description: "next observer")
        next.didSubscribe = { subscribed.fulfill() }
        let cancelled = Task { try await next.wait(for: self.request(nextCapture)) }
        await fulfillment(of: [subscribed], timeout: 2)
        cancelled.cancel()
        do { _ = try await self.value(cancelled); XCTFail("Cancelled wait succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError) }
        let later = self.item(nextCapture)
        await self.history.append(later)
        self.history.finishAutomationCapture(id: nextCapture, item: later)
    }
}

private final class AwaitHistoryFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [self.root] : super.urls(for: directory, in: domainMask)
    }
}
#endif
