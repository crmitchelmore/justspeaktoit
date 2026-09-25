import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// Closing is bounded: a provider, recogniser or playback that ignores
// cancellation cannot hold the window open, and whatever finishes afterwards
// cannot reach the closed window or lose the recording it saved.

/// Opens only when told, whatever cancellation says, like a request or a
/// native call that never checks for it.
final class StubbornLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var arrived: Int { lock.withLock { arrivals } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                arrivals += 1
                if !opened { waiters.append(continuation) }
                return opened
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// Transcription that ignores cancellation and answers once its latch opens.
final class StubbornEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let latch = StubbornLatch()
    private let lock = NSLock()
    private var performed: [String] = []
    var outputs: [String] { lock.withLock { performed } }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await latch.wait()
        return TranscriptionResult(
            text: "Late transcript", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> String {
        lock.withLock { performed.append(text) }
        return "Delivered."
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// The report `close()` returned, once it has.
private final class ClosedReport: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DesktopHostShutdownReport?
    var value: DesktopHostShutdownReport? { lock.withLock { stored } }
    func set(_ report: DesktopHostShutdownReport) { lock.withLock { stored = report } }
}

final class DesktopHostShutdownTests: XCTestCase {
    private var directory: URL!
    private var effects: StubbornEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shutdown-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = StubbornEffects()
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(200)
        )
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: DesktopHostModels.all[batchIndex].id))
        FakeLog.shared.setKey("synthetic-key", name: credential.apiKeyIdentifier)
    }

    override func tearDown() async throws {
        effects.latch.open()
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private var history: URL { directory.appendingPathComponent("History") }

    /// The records as saved, read without recovering any.
    private func records() async throws -> [DesktopRecordingStore.Record] {
        try await DesktopRecordingStore(directory: history).records()
    }

    private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    /// Records into a field, then stops; the transcription never honours cancellation.
    private func stopIntoAStuckTranscription() async throws -> Task<Void, Never> {
        await controller.toggle(
            target: "editor", modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
        let stopping = Task {
            await self.controller.toggle(
                target: nil, modelIndex: self.batchIndex, deviceID: "", targetExecutablePath: nil,
                textOutput: FakeTextOutput()
            )
        }
        try await waitFor("the provider request") { self.effects.latch.arrived == 1 }
        return stopping
    }

    /// Closes in a task and returns its report once it has, or nil after
    /// `seconds`, so a close that never returns fails instead of hanging.
    private func close(within seconds: Int) async throws -> DesktopHostShutdownReport? {
        let report = ClosedReport()
        let controller = controller!
        Task { report.set(await controller.close()) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while report.value == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return report.value
    }

    func testCloseEndsAfterItsGraceWhenAProviderIgnoresCancellation() async throws {
        let stopping = try await stopIntoAStuckTranscription()
        let saved = try await records()
        let pending = try XCTUnwrap(saved.first)
        XCTAssertNil(pending.result, "The recording was saved before the request")
        XCTAssertNil(pending.failure)
        let started = ContinuousClock.now
        guard let report = try await close(within: 5) else {
            XCTFail("close() is still waiting for an operation that ignores cancellation")
            effects.latch.open()
            return await stopping.value
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(report.unfinishedOperations, 1)
        XCTAssertTrue(report.playbackClosed && report.discoveryEnded)
        XCTAssertFalse(report.isComplete)
        let again = await controller.close()
        XCTAssertEqual(again, report, "A later close returns at once with the same outcome")

        // Quitting now leaves the saved recording; the next launch recovers it with its audio.
        let nextLaunch = directory.appendingPathComponent("NextLaunch")
        try FileManager.default.copyItem(at: history, to: nextLaunch)
        let relaunched = try await DesktopRecordingStore(directory: nextLaunch).recoverInterruptedRecordings().records
        let recovered = try XCTUnwrap(relaunched.first)
        XCTAssertEqual(recovered.id, pending.id)
        XCTAssertEqual(recovered.failure, "Recording was interrupted. Audio recovered for retry.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: nextLaunch.appendingPathComponent(recovered.audioFilename).path
        ))
        effects.latch.open()
        await stopping.value
    }

    func testWorkFinishingAfterCloseNeverReachesTheWindowOrTheField() async throws {
        let stopping = try await stopIntoAStuckTranscription()
        guard let report = try await close(within: 5) else {
            XCTFail("close() is still waiting for an operation that ignores cancellation")
            effects.latch.open()
            return await stopping.value
        }
        XCTAssertEqual(report.unfinishedOperations, 1)
        let shown = FakeLog.shared.allStatuses
        effects.latch.open()
        await stopping.value
        try await waitFor("the late operation to finish") { await self.controller.activeOperations == 0 }
        XCTAssertEqual(FakeLog.shared.allStatuses, shown, "Nothing reached the closed window")
        XCTAssertTrue(effects.outputs.isEmpty, "Nothing was inserted after closing")
        let saved = try await records()
        let record = try XCTUnwrap(saved.first)
        XCTAssertEqual(record.result?.text, "Late transcript", "A response that arrives is still saved")
        XCTAssertEqual(record.failure, "Cancelled. Completed transcription and audio retained.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent(record.audioFilename).path))
    }

    func testCloseWithNothingRunningIsComplete() async throws {
        let report = await controller.close()
        XCTAssertTrue(report.isComplete)
    }

    func testABoundedWaitGivesUpOnWorkThatNeverEnds() async {
        let latch = StubbornLatch()
        let ended = await DesktopHostShutdown.wait(within: .milliseconds(50)) { await latch.wait() }
        XCTAssertFalse(ended)
        let finished = await DesktopHostShutdown.wait(within: .seconds(5)) {}
        XCTAssertTrue(finished)
        latch.open()
    }
}
