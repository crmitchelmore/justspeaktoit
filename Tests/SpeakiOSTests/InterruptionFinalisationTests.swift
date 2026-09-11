#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class InterruptionFinalisationTests: XCTestCase {
    func testInterruption_destinationsKeepOneResultWithoutDeferredError() async throws {
        for destination: HardwareTriggerDestination in [.historyOnly, .clipboard, .clipboardAndPostProcess] {
            let harness = try Harness()
            defer { harness.cleanUp() }
            try await harness.start(destination: destination)
            harness.session.emitPartial("Captured words")
            harness.session.interrupt()
            harness.session.interrupt()
            harness.session.endInterruption()
            await settle(until: harness.service.state == .idle)
            XCTAssertEqual(harness.session.stops, 1)
            XCTAssertEqual(harness.service.state, .idle)
            XCTAssertFalse(harness.shared.isRecording)
            XCTAssertNil(harness.service.lastSessionError)
            XCTAssertEqual(harness.service.captureStopNotice, iOSTranscriptionError.interrupted.localizedDescription)
            XCTAssertEqual(harness.history.items.count, 1)
            XCTAssertEqual(harness.history.items.first?.transcription, "Captured words")
            XCTAssertEqual(harness.pasteboard.string, destination == .historyOnly ? "Original" : "Captured words")
            XCTAssertEqual(harness.pasteboard.writes, destination == .historyOnly ? 0 : 1)
        }
    }

    func testInterruptedPolish_copiesRawThenUsesTheOriginalPolishPolicy() async throws {
        let harness = try Harness(polishing: true)
        defer { harness.cleanUp() }
        try await harness.start(destination: .clipboardAndPostProcess)
        harness.session.emitPartial("Raw words")
        harness.session.interrupt()
        await settle(until: harness.service.state == .idle && !harness.service.isPostProcessing)
        XCTAssertEqual(harness.history.items.count, 1)
        XCTAssertEqual(harness.history.items.first?.transcription, "Raw words")
        XCTAssertEqual(harness.history.items.first?.postProcessedTranscription, "Polished Raw words")
        // The raw transcript is copied once at stop; polish lands in History and
        // the shared result, never as a delayed clipboard rewrite (issue #934).
        XCTAssertEqual(harness.pasteboard.string, "Raw words")
        XCTAssertEqual(harness.pasteboard.writes, 1)
        XCTAssertEqual(harness.shared.lastCompletedTranscript, "Polished Raw words")
        XCTAssertNil(harness.service.lastSessionError)
    }

    func testEmptyInterruption_keepsClipboardAndDoesNotInventText() async throws {
        for text in ["", " \n\t "] {
            let harness = try Harness()
            defer { harness.cleanUp() }
            try await harness.start(destination: .clipboard)
            harness.session.emitPartial(text)
            harness.session.interrupt()
            await settle(until: harness.service.state == .idle)
            XCTAssertEqual(harness.pasteboard.string, "Original")
            XCTAssertEqual(harness.pasteboard.writes, 0)
            XCTAssertTrue(harness.history.items.allSatisfy { $0.transcription.isEmpty })
            XCTAssertNil(harness.service.lastSessionError)
        }
    }

    func testKeyboardInterruption_delegatesToOriginalCompletionWithoutLegacyOutput() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        var results: [String] = []
        try await harness.service.startRecording(
            sharesLiveTranscript: false, requiresLiveActivity: false, destination: .historyOnly,
            onCaptureDisruption: {
                let result = await harness.service.stopRecording(destination: .historyOnly, saveToHistory: false)
                results.append(result.text)
            }
        )
        harness.session.emitPartial("Keyboard words")
        harness.session.interrupt()
        await settle(until: harness.service.state == .idle)
        XCTAssertEqual(results, ["Keyboard words"])
        XCTAssertTrue(harness.history.items.isEmpty)
        XCTAssertEqual(harness.pasteboard.writes, 0)
        XCTAssertNotEqual(harness.shared.lastCompletedTranscript, "Keyboard words")
        XCTAssertNil(harness.service.lastSessionError)
    }

    func testConcurrentStopAndDrainFailure_keepsPartialAndReportsRealError() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let draining = expectation(description: "draining")
        var finish: CheckedContinuation<TranscriptionResult, Error>?
        harness.session.finish = {
            try await withCheckedThrowingContinuation {
                finish = $0
                draining.fulfill()
            }
        }
        try await harness.start(destination: .historyOnly)
        harness.session.emitPartial("Available partial")
        harness.session.interrupt()
        await fulfillment(of: [draining], timeout: 2)
        _ = await harness.service.stopRecording(destination: .clipboard)
        harness.session.onError?(iOSTranscriptionError.microphoneChanged)
        harness.session.endInterruption()
        XCTAssertFalse(harness.shared.isRecording)
        XCTAssertEqual(harness.service.state, .stopping)
        finish?.resume(throwing: TestFailure.drain)
        // The bounded stop unwinds a deadline task group before the owner can
        // publish, so wait for the run to settle rather than a fixed number of hops.
        await settle(until: harness.service.state == .idle)
        XCTAssertEqual(harness.session.stops, 1)
        XCTAssertEqual(harness.history.items.count, 1)
        XCTAssertEqual(harness.history.items.first?.transcription, "Available partial")
        XCTAssertTrue(harness.service.lastSessionError is TestFailure)
        XCTAssertEqual(harness.pasteboard.writes, 0)
    }

    func testCancelDuringInterruptionDrain_suppressesOutputAndOldCallbacksCannotStopNextRun() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let draining = expectation(description: "draining")
        var finish: CheckedContinuation<TranscriptionResult, Error>?
        harness.session.finish = {
            try await withCheckedThrowingContinuation {
                finish = $0
                draining.fulfill()
            }
        }
        try await harness.start(destination: .clipboard)
        let oldError = harness.session.onError
        let oldPartial = harness.session.onPartialResult
        harness.session.emitPartial("Cancelled words")
        harness.session.interrupt()
        await fulfillment(of: [draining], timeout: 2)
        harness.service.cancelRecording()
        finish?.resume(returning: InterruptionSession.result("Cancelled words"))
        await settle()
        XCTAssertTrue(harness.history.items.isEmpty)
        XCTAssertEqual(harness.pasteboard.writes, 0)
        let next = InterruptionSession()
        harness.service.makeSession = { next }
        try await harness.start(destination: .historyOnly)
        oldError?(iOSTranscriptionError.interrupted)
        oldPartial?("Late old text", false)
        harness.session.endInterruption()
        await settle()
        XCTAssertTrue(harness.service.isRunning)
        XCTAssertEqual(harness.service.partialText, "")
        XCTAssertNil(harness.service.captureStopNotice)
        harness.service.cancelRecording()
    }

    func testQueuedBeginAfterCancel_cannotTerminateReplacementRun() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try await harness.start(destination: .clipboard)
        harness.session.interrupt()
        harness.service.cancelRecording()
        try await harness.start(destination: .historyOnly)
        await settle()
        XCTAssertTrue(harness.service.isRunning)
        XCTAssertEqual(harness.session.stops, 0)
        XCTAssertTrue(harness.history.items.isEmpty)
        harness.service.cancelRecording()
    }

    func testForegroundInterruption_finalisesOwnerAndPreservesPartialOnRealFailure() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let coordinator = TranscriberCoordinator(sharedState: harness.shared, historyManager: harness.history)
        coordinator.makeSession = { harness.session }
        harness.session.finish = { throw TestFailure.drain }
        try await coordinator.start()
        harness.session.emitPartial("Foreground words")
        harness.session.interrupt()
        await settle()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(harness.shared.isRecording)
        XCTAssertEqual(harness.session.stops, 1)
        XCTAssertEqual(harness.history.items.count, 1)
        XCTAssertEqual(harness.history.items.first?.transcription, "Foreground words")
        XCTAssertTrue(coordinator.error is TestFailure)
        XCTAssertEqual(coordinator.captureStopNotice, iOSTranscriptionError.interrupted.localizedDescription)
        XCTAssertEqual(harness.pasteboard.writes, 0)
        coordinator.cancel()
    }

    func testForegroundSuccess_hasNoErrorAndIgnoresRetiredOwnerCallbacks() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let coordinator = TranscriberCoordinator(sharedState: harness.shared, historyManager: harness.history)
        coordinator.makeSession = { harness.session }
        try await coordinator.start()
        let oldError = harness.session.onError
        let oldPartial = harness.session.onPartialResult
        harness.session.emitPartial("Foreground success")
        harness.session.interrupt()
        await settle()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(harness.history.items.count, 1)
        let next = InterruptionSession()
        coordinator.makeSession = { next }
        try await coordinator.start()
        oldError?(iOSTranscriptionError.interrupted)
        oldPartial?("Retired words", false)
        harness.session.endInterruption()
        await settle()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(coordinator.partialText, "")
        XCTAssertNil(coordinator.captureStopNotice)
        coordinator.cancel()
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    private func settle(until condition: @autoclosure @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await settle()
    }
}

private enum TestFailure: Error { case drain }

@MainActor
private final class Harness {
    let suite = "InterruptionFinalisation.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let shared: SharedTranscriptionState
    let history: iOSHistoryManager
    let pasteboard = InterruptionPasteboard()
    let session = InterruptionSession()
    let service: TranscriptionRecordingService

    init(polishing: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        shared = SharedTranscriptionState(defaults: defaults)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = iOSHistoryManager(fileURL: directory.appendingPathComponent("history.json"),
                                    syncEnabled: false, userDefaults: defaults)
        service = TranscriptionRecordingService(
            sharedState: shared, historyManager: history,
            polishClipboard: PolishClipboard(pasteboard: pasteboard),
            hasPolishingKey: { polishing }, polish: { text, _, _ in "Polished \(text)" }
        )
        service.makeSession = { [session] in session }
    }

    func start(destination: HardwareTriggerDestination) async throws {
        try await service.startRecording(requiresLiveActivity: false, destination: destination)
    }

    func cleanUp() {
        service.cancelRecording()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class InterruptionSession: IOSRecordingSession {
    let isBatch = false
    let resolution = IOSTranscriptionSession.Resolution(modelID: "test", backend: .apple, route: nil)
    var partialText = ""
    let confidence: Double? = nil
    var onPartialResult: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onFirstInputBuffer: (() -> Void)?
    var onStartupObservation: ((StartupObservation) -> Void)?
    var inputLevelSample = CaptureInputLevelSample(levelDBFS: -160, sequence: 0)
    let safetyRecordingID: UUID? = nil
    var discards = 0
    var stops = 0
    var finish: (() async throws -> TranscriptionResult)?
    private let observer = CaptureDisruptionObserver()

    func start() async throws {
        partialText = ""
        observer.observeAudioInterruption { [weak self] in self?.onError?(iOSTranscriptionError.interrupted) }
    }
    func start(preRollBuffers: [AVAudioPCMBuffer], analyzerFallbackAllowed: Bool) async throws {
        try await start()
    }
    func stop() async throws -> TranscriptionResult {
        observer.stop()
        stops += 1
        if let finish { return try await finish() }
        return Self.result(partialText)
    }
    func cancel() { observer.stop() }
    func resetInputLevel() {}
    @discardableResult
    func discardTemporaryRecording() -> Bool {
        discards += 1
        return true
    }
    func emitPartial(_ text: String) {
        partialText = text
        onPartialResult?(text, false)
    }
    func interrupt() { Self.post(.began) }
    func endInterruption() { Self.post(.ended) }
    static func post(_ type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                                   AVAudioSessionInterruptionOptionKey:
                                                    AVAudioSession.InterruptionOptions.shouldResume.rawValue])
    }
    static func result(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: [], confidence: nil, duration: 1,
                            modelIdentifier: "test", cost: nil, rawPayload: nil, debugInfo: nil)
    }
}

@MainActor
private final class InterruptionPasteboard: PolishPasteboard {
    var string: String? = "Original"
    var writes = 0
    func write(_ text: String) {
        string = text
        writes += 1
    }
}
#endif
