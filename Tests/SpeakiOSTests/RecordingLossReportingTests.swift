#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class RecordingLossReportingTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() async throws {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        try await super.tearDown()
    }

    func testFactoryOwners_reportOnceWithoutErrorAndPersistDrainedSummary() async throws {
        // Includes analyser/legacy Apple factory routes, OpenAI, shared live and batch.
        for (model, mode) in cases {
            let session = try makeSession(model: model, mode: mode)
            let recorder = session.recordingPersistenceForTesting
            let reporting = session.recordingLoss
            var warnings: [String] = []
            session.onRecordingWarning = { warnings.append($0) }
            session.onError = { _ in XCTFail("A recording warning must not enter the fatal callback") }
            reporting.begin(recorder: recorder)
            let run = reporting.currentReport
            let buffer = try makeBuffer()
            reporting.startWriter(recorder, format: buffer.format)
            urls.append(try XCTUnwrap(recorder.currentFileURL))

            // Exhaust the real capture pool; writer never sees these upstream gaps.
            let pool = PCMBufferPool(maximumBuffers: 1)
            let held = try XCTUnwrap(run.copyCapture(buffer, using: pool))
            XCTAssertNil(run.copyCapture(buffer, using: pool))
            XCTAssertNil(run.copyCapture(buffer, using: pool))
            reporting.deliverWarningIfNeeded()
            reporting.deliverWarningIfNeeded()
            pool.recycle(held)
            let retained = try XCTUnwrap(run.copyCapture(buffer, using: pool))
            recorder.writeBuffer(retained)
            pool.recycle(retained)
            let info = try XCTUnwrap(reporting.finish(recorder: recorder, run: run))
            XCTAssertEqual(warnings.count, 1, model)
            XCTAssertEqual(run.snapshot.rejectedBuffers, 2, model)
            XCTAssertEqual(run.snapshot.captureSeconds, 0.2, accuracy: 0.000001)
            XCTAssertEqual(info.diagnostics?.droppedFrames, 0)
            XCTAssertEqual(info.diagnostics?.admittedFrames, 1)
            XCTAssertGreaterThan(info.fileSize, 0)
            XCTAssertNotNil(session.recordingLossSummary)
            try assertHistoryReload(summary: XCTUnwrap(session.recordingLossSummary), model: model)
        }
    }

    func testWriterOverflowAndSustainedPressure_keepDistinctDrainedTotals() async throws {
        let recorder = AudioRecordingPersistence()
        let reporting = RecordingLossReporting()
        var warnings: [String] = []
        reporting.onWarning = { warnings.append($0) }
        let buffer = try makeBuffer()
        reporting.begin(recorder: recorder)
        reporting.startWriter(recorder, format: buffer.format)
        urls.append(try XCTUnwrap(recorder.currentFileURL))
        let entered = expectation(description: "writer stalled")
        let release = DispatchSemaphore(value: 0)
        let stall = FirstWriteStall(entered: { entered.fulfill() }, release: release)
        recorder.beforeFileWrite = { stall.waitOnce() }
        defer { release.signal() }
        recorder.writeBuffer(buffer)
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<7 { XCTAssertEqual(recorder.writeBuffer(buffer), .accepted) }
        XCTAssertEqual(recorder.writeBuffer(buffer), .acceptedViaOverflow)
        reporting.deliverWarningIfNeeded()
        XCTAssertTrue(warnings.isEmpty, "Accepted overflow alone is healthy")
        var drops = 0
        for _ in 0..<30 where recorder.writeBuffer(buffer) == .backpressured { drops += 1 }
        XCTAssertGreaterThan(drops, 0)
        // The callback runs off the audio thread; wait for the actual owner callback.
        for _ in 0..<100 where reporting.currentReport.snapshot.persistence.isComplete {
            try await Task.sleep(for: .milliseconds(10))
        }
        reporting.deliverWarningIfNeeded()
        release.signal()
        let info = try XCTUnwrap(reporting.finish(recorder: recorder, run: reporting.currentReport))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(info.diagnostics?.droppedFrames, drops)
        XCTAssertEqual(try XCTUnwrap(info.diagnostics).droppedSeconds, Double(drops) * 0.1, accuracy: 0.000001)
        XCTAssertEqual(info.diagnostics?.writeFailures, 0)
        XCTAssertEqual(reporting.currentReport.snapshot.rejectedBuffers, 0)
        XCTAssertGreaterThan(info.fileSize, 0)
    }

    func testWriteFailures_drainEvenBeforeNotificationThenCancelAndRestart() throws {
        for (model, mode) in cases {
            let session = try makeSession(model: model, mode: mode)
            let reporting = session.recordingLoss
            let recorder = session.recordingPersistenceForTesting
            var warnings: [String] = []
            session.onRecordingWarning = { warnings.append($0) }
            reporting.begin(recorder: recorder)
            let oldRun = reporting.currentReport
            let oldCallback = try XCTUnwrap(recorder.onPersistenceIssue)
            let buffer = try makeBuffer()
            reporting.startWriter(recorder, format: buffer.format)
            urls.append(try XCTUnwrap(recorder.currentFileURL))
            recorder.beforeFileWrite = { throw CocoaError(.fileWriteOutOfSpace) }
            for _ in 0..<3 { recorder.writeBuffer(buffer) }
            let info = try XCTUnwrap(reporting.finish(recorder: recorder, run: oldRun))
            XCTAssertEqual(info.diagnostics?.writeFailures, 3)
            XCTAssertEqual(oldRun.snapshot.persistence.writeFailures, 3)
            XCTAssertTrue(session.recordingLossSummary?.contains("3 write failures") == true)
            XCTAssertEqual(warnings.count, 0, "Stop totals must not depend on queued warning delivery")

            reporting.begin(recorder: recorder)
            recorder.beforeFileWrite = nil
            reporting.startWriter(recorder, format: buffer.format)
            let discarded = try XCTUnwrap(recorder.currentFileURL)
            reporting.cancel()
            recorder.cancelRecording()
            XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
            reporting.begin(recorder: recorder)
            reporting.startWriter(recorder, format: buffer.format)
            urls.append(try XCTUnwrap(recorder.currentFileURL))
            var late = RecordingPersistenceDiagnostics()
            late.writeFailures = 1
            oldCallback(late)
            reporting.deliverWarningIfNeeded()
            XCTAssertEqual(warnings.count, 0)
            XCTAssertNil(reporting.finish(recorder: recorder, run: oldRun), "Old stop cannot close the new writer")
            XCTAssertTrue(recorder.isRecording)
            recorder.writeBuffer(buffer)
            let clean = try XCTUnwrap(reporting.finish(recorder: recorder, run: reporting.currentReport))
            XCTAssertTrue(clean.diagnostics?.isComplete == true)
            XCTAssertNil(session.recordingLossSummary)
        }
    }

    private var cases: [(String, IOSTranscriptionSession.Mode)] {
        [
            (AppleLocalModels.preferredSpeechModelID, .streaming),
            (AppleLocalModels.legacySpeechModelID, .streaming),
            ("openai/gpt-4o-mini-transcribe", .streaming),
            ("deepgram/nova-3-streaming", .streaming),
            ("openai/gpt-4o-mini-transcribe", .batch(retainRecording: true))
        ]
    }

    private func makeSession(model: String, mode: IOSTranscriptionSession.Mode) throws -> IOSTranscriptionSession {
        try IOSTranscriptionSession(
            modelID: model, mode: mode, audioSessionManager: AudioSessionManager(),
            batchAPIKey: "test", liveAPIKey: { _ in "test" }
        )
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        if let samples = buffer.floatChannelData?[0] { samples.initialize(repeating: 0, count: 4_800) }
        return buffer
    }

    private func assertHistoryReload(summary: String, model: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let manager = iOSHistoryManager(fileURL: file, syncEnabled: false)
        let item = try XCTUnwrap(manager.recordTranscription(
            text: "Available words", model: model, duration: 1, errorMessage: summary
        ))
        manager.beginPostProcessing(for: item.id)
        manager.setPostProcessed("Available words.", for: item.id, preservingError: summary)
        let reloaded = iOSHistoryManager(fileURL: file, syncEnabled: false)
        XCTAssertEqual(reloaded.items.first?.errorMessage, summary)
        XCTAssertEqual(reloaded.items.first?.transcription, "Available words")
        XCTAssertEqual(reloaded.items.first?.postProcessedTranscription, "Available words.")
        XCTAssertNil(manager.recordTranscription(text: " ", model: model, duration: 1, errorMessage: summary))
    }
}

private final class FirstWriteStall: @unchecked Sendable {
    private let lock = NSLock()
    private var didStall = false
    private let entered: @Sendable () -> Void
    private let release: DispatchSemaphore

    init(entered: @escaping @Sendable () -> Void, release: DispatchSemaphore) {
        self.entered = entered
        self.release = release
    }

    func waitOnce() {
        let shouldStall = lock.withLock {
            if didStall { return false }
            didStall = true
            return true
        }
        if shouldStall {
            entered()
            _ = release.wait(timeout: .now() + 5)
        }
    }
}
#endif
