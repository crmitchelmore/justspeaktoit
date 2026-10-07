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

/// A capture whose stop blocks its thread until released, like an audio
/// device or file system that stalls.
final class StallingCapture: DesktopRecordingCapture, @unchecked Sendable {
    private let synthetic: SyntheticCapture
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stops = 0

    init(context: DesktopCaptureContext) { synthetic = SyntheticCapture(context: context) }

    var stopCalls: Int { lock.withLock { stops } }
    func release() { gate.signal() }

    func start() throws { try synthetic.start() }
    func stop() throws {
        lock.withLock { stops += 1 }
        gate.wait()
    }
    func destroy() {}
}

/// A live provider session that reports one transcript and records when it
/// ends. With `blocksCancellation`, cancelling blocks its thread until
/// `releaseCancellation()`, like a provider stuck tearing down its socket.
final class RecordingLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    let finalisationBudget: TimeInterval? = nil
    private let lock = NSLock()
    private let cancellationGate = DispatchSemaphore(value: 0)
    private let blocksCancellation: Bool
    private var ended = false
    var isEnded: Bool { lock.withLock { ended } }

    init(blocksCancellation: Bool = false) { self.blocksCancellation = blocksCancellation }

    func releaseCancellation() { cancellationGate.signal() }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        onTranscript("Words spoken before closing", true)
    }
    func sendAudio(_ audioData: Data) {}
    func stop() { lock.withLock { ended = true } }
    func cancel() {
        if blocksCancellation { cancellationGate.wait() }
        stop()
    }
    func finishAndWait() async -> String? {
        stop()
        return nil
    }
}

/// Transcription that ignores cancellation and answers once its latch opens.
final class StubbornEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let latch = StubbornLatch()
    private let lock = NSLock()
    private var performed: [String] = []
    private var stalling: StallingCapture?
    private var stallsNextCapture = false
    private var live: RecordingLiveClient?
    /// Served to the next live recording, when set.
    var liveClient: RecordingLiveClient? {
        get { lock.withLock { live } }
        set { lock.withLock { live = newValue } }
    }
    var outputs: [String] { lock.withLock { performed } }
    /// The last capture made after `stallNextCapture()`.
    var stalledCapture: StallingCapture? { lock.withLock { stalling } }
    func stallNextCapture() { lock.withLock { stallsNextCapture = true } }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        lock.withLock { () -> any DesktopRecordingCapture in
            guard stallsNextCapture else { return SyntheticCapture(context: context) }
            stallsNextCapture = false
            let capture = StallingCapture(context: context)
            stalling = capture
            return capture
        }
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { liveClient }
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
        effects.stalledCapture?.release()
        effects.liveClient?.releaseCancellation()
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

    func testCloseEndsAfterItsGraceWhenStoppingTheOpenRecordingStalls() async throws {
        effects.stallNextCapture()
        await controller.toggle(
            target: "editor", modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
        let capture = try XCTUnwrap(effects.stalledCapture)
        let saved = try await records()
        let pending = try XCTUnwrap(saved.first)
        XCTAssertNil(pending.result, "The recording was saved when it began")
        XCTAssertNil(pending.failure)
        let started = ContinuousClock.now
        guard let report = try await close(within: 5) else {
            XCTFail("close() is still waiting for a recording whose capture never stops")
            return capture.release()
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertFalse(report.recordingSaved)
        XCTAssertEqual(report.unfinishedOperations, 0)
        XCTAssertFalse(report.isComplete)

        // Quitting now leaves the record saved when recording began; the next
        // launch recovers it with the audio captured so far.
        let nextLaunch = directory.appendingPathComponent("NextLaunch")
        try FileManager.default.copyItem(at: history, to: nextLaunch)
        let relaunched = try await DesktopRecordingStore(directory: nextLaunch).recoverInterruptedRecordings().records
        let recovered = try XCTUnwrap(relaunched.first)
        XCTAssertEqual(recovered.id, pending.id)
        XCTAssertEqual(recovered.failure, "Recording was interrupted. Audio recovered for retry.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: nextLaunch.appendingPathComponent(recovered.audioFilename).path
        ))

        // A stop that ends later still finalises the audio and saves the record.
        capture.release()
        try await waitFor("the late stop to save the recording") {
            try await self.records().first?.failure == "Recording stopped when the app closed. Audio retained."
        }
        let audio = history.appendingPathComponent(pending.audioFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    /// Starts a live recording with `client` on a model that needs no Azure resource.
    private func startLiveRecording(with client: RecordingLiveClient) async throws {
        DesktopHostModels.configure(streamingQualified: true)
        let liveIndex = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopHostModels.isLive($0.id) && DesktopLiveTranscription.route(forID: $0.id)?.provider != .azure
        })
        let model = DesktopHostModels.all[liveIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model))
        FakeLog.shared.setKey("synthetic-key", name: credential.apiKeyIdentifier)
        effects.liveClient = client
        await controller.toggle(
            target: "editor", modelIndex: liveIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
    }

    func testCloseEndsAfterItsGraceWhenTheLiveProviderBlocksInCancellation() async throws {
        let client = RecordingLiveClient(blocksCancellation: true)
        try await startLiveRecording(with: client)
        let started = ContinuousClock.now
        guard let report = try await close(within: 5) else {
            XCTFail("close() is still waiting for a provider that never finishes cancelling")
            return client.releaseCancellation()
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertFalse(report.recordingSaved)

        // Once the provider lets go, the recording is saved with its audio and live text.
        client.releaseCancellation()
        try await waitFor("the late save of the live recording") {
            try await self.records().first?.result?.text == "Words spoken before closing"
        }
    }

    func testClosingEndsTheLiveSessionEvenWhenStoppingTheCaptureStalls() async throws {
        let client = RecordingLiveClient()
        effects.stallNextCapture()
        try await startLiveRecording(with: client)
        let capture = try XCTUnwrap(effects.stalledCapture)
        XCTAssertFalse(client.isEnded, "The live session is streaming")
        guard let report = try await close(within: 5) else {
            XCTFail("close() is still waiting for a recording whose capture never stops")
            return capture.release()
        }
        XCTAssertFalse(report.recordingSaved)
        XCTAssertTrue(client.isEnded, "The provider session outlived closing")

        // The live text so far is saved once the stalled stop ends.
        capture.release()
        try await waitFor("the late stop to save the live text") {
            try await self.records().first?.result?.text == "Words spoken before closing"
        }
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
