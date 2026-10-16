import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class TailCapture: DesktopRecordingCapture, @unchecked Sendable {
    let context: DesktopCaptureContext
    private let lock = NSLock()
    private var stops = 0
    private var destroys = 0
    var failStart = false
    var failStop = false
    var stopCount: Int { lock.withLock { stops } }
    var destroyCount: Int { lock.withLock { destroys } }

    init(context: DesktopCaptureContext) { self.context = context }
    func start() throws {
        if failStart { throw DesktopHostError(message: "Synthetic capture start failed.") }
        appendFrame()
    }
    func stop() throws {
        lock.withLock { stops += 1 }
        if failStop { throw DesktopHostError(message: "Synthetic capture stop failed.") }
    }
    func destroy() { lock.withLock { destroys += 1 } }
    func appendFrame() {
        let samples: [Int16] = (0..<1_600).map { Int16(($0 % 32) * 256 - 4_000) }
        samples.withUnsafeBufferPointer { context.receive($0.baseAddress!, count: $0.count) }
    }
}

final class TailLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    let finalisationBudget: TimeInterval? = nil
    private let lock = NSLock()
    private var frames = 0
    private var sizes: [Int] = []
    private var finishes = 0
    private var transcriptHandler: ((String, Bool) -> Void)?
    var frameCount: Int { lock.withLock { frames } }
    var frameSizes: [Int] { lock.withLock { sizes } }
    var finishCount: Int { lock.withLock { finishes } }
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { transcriptHandler = onTranscript }
        onTranscript("Live tail transcript", true)
    }
    func interim(_ text: String) { lock.withLock { transcriptHandler }?(text, false) }
    func sendAudio(_ audioData: Data) { lock.withLock { frames += 1; sizes.append(audioData.count) } }
    func stop() {}
    func cancel() {}
    func finishAndWait() async -> String? {
        lock.withLock { finishes += 1 }
        return "Live tail transcript"
    }
}

final class TailEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let live = TailLiveClient()
    private let lock = NSLock()
    private var storedCapture: TailCapture?
    private var requests: [DesktopHostTranscriptionRequest] = []
    private var performed = 0
    private var jobs: [FakeJob] = []
    private var targetRequests = 0
    private var storedTarget: String? = "synthetic-field"
    private var storedExecutablePath: String?
    private var contextRequests = 0
    private var storedDelivery = DesktopTextOutputResult(.confirmedInsertion, status: "Delivered.")
    var target: String? {
        get { lock.withLock { storedTarget } }
        set { lock.withLock { storedTarget = newValue } }
    }
    var delivery: DesktopTextOutputResult {
        get { lock.withLock { storedDelivery } }
        set { lock.withLock { storedDelivery = newValue } }
    }
    var executablePath: String? {
        get { lock.withLock { storedExecutablePath } }
        set { lock.withLock { storedExecutablePath = newValue } }
    }
    var contextRequestCount: Int { lock.withLock { contextRequests } }
    let targetGate = Gate(open: true)
    let transcriptionGate = Gate(open: true)
    let outputGate = Gate(open: true)
    var targetRequestCount: Int { lock.withLock { targetRequests } }
    var outputJobs: [FakeJob] { lock.withLock { jobs } }
    var failStart = false
    var failTranscription = false
    var failSettingsWrite = false
    var capture: TailCapture? { lock.withLock { storedCapture } }
    var transcriptions: [DesktopHostTranscriptionRequest] { lock.withLock { requests } }
    var outputCount: Int { lock.withLock { performed } }
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        let capture = TailCapture(context: context)
        capture.failStart = failStart
        lock.withLock { storedCapture = capture }
        return capture
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { live }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        lock.withLock { requests.append(request) }
        await transcriptionGate.pass()
        try Task.checkCancellation()
        if failTranscription { throw DesktopHostError(message: "Synthetic transcription failure.") }
        return TranscriptionResult(
            text: "Batch tail transcript", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func captureInsertionTarget() async throws -> String? {
        let captured = lock.withLock { targetRequests += 1; return storedTarget }
        await targetGate.pass()
        return captured
    }
    func captureUtteranceContext(
        requiresInsertionTarget: Bool
    ) async throws -> DesktopHostUtteranceContext<String> {
        let context = lock.withLock {
            contextRequests += 1
            if requiresInsertionTarget { targetRequests += 1 }
            return DesktopHostUtteranceContext(
                target: requiresInsertionTarget ? storedTarget : nil, executablePath: storedExecutablePath
            )
        }
        await targetGate.pass()
        return context
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        lock.withLock { performed += 1; jobs.append(job) }
        while !outputGate.isOpen, !Task.isCancelled { Thread.sleep(forTimeInterval: 0.002) }
        return delivery
    }
    func writeSettings(_ data: Data, to url: URL) throws {
        if failSettingsWrite { throw DesktopHostError(message: "Synthetic settings write failure.") }
        try data.write(to: url, options: .atomic)
    }
}

final class DesktopHostRecordingTailTests: XCTestCase {
    private var directory: URL!
    private var effects: TailEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tail-tests-\(UUID().uuidString)")
        effects = TailEffects()
        controller = try DesktopHostController<FakePlatform>(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(500)
        )
        await controller.markReadyForSelfTest()
        batchIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        for model in DesktopHostModels.all {
            if let provider = DesktopHostModels.provider(for: model.id) {
                FakeLog.shared.setKey("synthetic-key", name: provider.apiKeyIdentifier)
            }
        }
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func setTail(_ seconds: Double) async throws {
        let preferences = try DesktopConfiguration(values: [
            "postRecordingTailDuration": AnyCodable(.double(seconds))
        ])
        try await controller.saveConfiguration(preferences.entries)
    }

    private func toggle(index: Int? = nil, target: String? = nil) async {
        await controller.toggle(
            target: target, modelIndex: index ?? batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
    }

    private func waitForTail() async throws {
        for _ in 0..<1_000 {
            if await controller.recordingTail != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Recording tail did not start.")
        throw DesktopHostError(message: "Recording tail did not start.")
    }

    private func saved() async throws -> [DesktopRecordingStore.Record] {
        try await DesktopRecordingStore(directory: directory.appendingPathComponent("History")).records()
    }

    func testBufferKeepsCaptureOpenAndIncludesTrailingAudio() async throws {
        try await setTail(0.3)
        await toggle()
        let capture = try XCTUnwrap(effects.capture)
        let requested = ContinuousClock.now
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        capture.appendFrame()
        await stopping.value
        XCTAssertGreaterThanOrEqual(requested.duration(to: .now), .seconds(0.3))
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertEqual(effects.transcriptions.count, 1)
        XCTAssertEqual(effects.transcriptions.first?.duration ?? 0, 0.2, accuracy: 0.0001)
        let records = try await saved()
        XCTAssertEqual(records.first?.result?.text, "Batch tail transcript")
    }

    func testZeroBufferStopsWithoutAnOwnedDelay() async throws {
        try await setTail(0)
        await toggle()
        await toggle()
        let tail = await controller.recordingTail
        XCTAssertNil(tail)
        XCTAssertEqual(effects.capture?.stopCount, 1)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
        XCTAssertEqual(effects.transcriptions.count, 1)
    }

    func testCancelDuringBufferRetainsAudioWithoutTranscription() async throws {
        try await setTail(2)
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        await controller.cancelTranscription()
        await stopping.value
        XCTAssertEqual(effects.capture?.stopCount, 1)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        let records = try await saved()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.failure, "Recording cancelled. Audio retained.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("History").appendingPathComponent(record.audioFilename).path
        ))
        let busy = await controller.busy
        XCTAssertFalse(busy)
    }

    func testCaptureFailureOwnsCleanupAndCannotStopAReplacementRecording() async throws {
        try await setTail(2)
        await toggle()
        let failed = try XCTUnwrap(effects.capture)
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        failed.context.fail("Synthetic device loss")
        await stopping.value
        for _ in 0..<1_000 {
            if !(await controller.busy) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let records = try await saved()
        XCTAssertEqual(records.first?.failure, "Synthetic device loss")
        XCTAssertTrue(effects.transcriptions.isEmpty)
        XCTAssertEqual(failed.stopCount, 1)
        XCTAssertEqual(failed.destroyCount, 1)
        await toggle()
        let replacement = try XCTUnwrap(effects.capture)
        XCTAssertFalse(replacement === failed)
        XCTAssertEqual(FakeLog.shared.huds.last?.phase, .recording)
        XCTAssertEqual(replacement.stopCount, 0)
    }

    func testClosingDuringBufferCancelsDelayAndJoinsTheStopOwner() async throws {
        try await setTail(2)
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        let report = await controller.close()
        await stopping.value
        XCTAssertTrue(report.isComplete, "A two-second tail must not outlive the 500ms shutdown grace.")
        XCTAssertEqual(effects.capture?.stopCount, 1)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        let records = try await saved()
        XCTAssertEqual(records.first?.failure, "Recording stopped when the app closed. Audio retained.")
    }

    func testCancellingTheStopTaskStopsImmediatelyAndRetainsAudio() async throws {
        try await setTail(2)
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        stopping.cancel()
        await stopping.value
        XCTAssertEqual(effects.capture?.stopCount, 1)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        let records = try await saved()
        XCTAssertEqual(records.first?.failure, "Recording cancelled. Audio retained.")
    }

    func testDuplicateFinishDoesNotReplaceTheBufferOwner() async throws {
        try await setTail(2)
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        let owner = await controller.recordingTail?.recordID
        await toggle()
        let unchanged = await controller.recordingTail?.recordID
        XCTAssertEqual(unchanged, owner)
        XCTAssertEqual(effects.capture?.stopCount, 0)
        await controller.cancelTranscription()
        await stopping.value
        XCTAssertEqual(effects.capture?.stopCount, 1)
    }

    func testLivePCMContinuesDuringBufferBeforeProviderFinalisation() async throws {
        try await setTail(0.3)
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id.hasPrefix("deepgram/") && DesktopHostModels.isLive($0.id)
        })
        await toggle(index: index)
        let capture = try XCTUnwrap(effects.capture)
        let before = effects.live.frameCount
        let stopping = Task { await self.toggle(index: index) }
        try await waitForTail()
        capture.appendFrame()
        XCTAssertGreaterThan(effects.live.frameCount, before)
        XCTAssertEqual(effects.live.finishCount, 0)
        await stopping.value
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(effects.live.finishCount, 1)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        let records = try await saved()
        XCTAssertEqual(records.first?.result?.text, "Live tail transcript")
    }

    func testCancelLiveBufferRetainsLockedTextWithoutFinalisationOrInsertion() async throws {
        try await setTail(2)
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id.hasPrefix("deepgram/") && DesktopHostModels.isLive($0.id)
        })
        await toggle(index: index, target: "editor")
        let stopping = Task { await self.toggle(index: index) }
        try await waitForTail()
        await controller.cancelTranscription()
        await stopping.value
        XCTAssertEqual(effects.capture?.stopCount, 1)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
        XCTAssertEqual(effects.live.finishCount, 0)
        XCTAssertEqual(effects.outputCount, 0)
        XCTAssertTrue(effects.transcriptions.isEmpty)
        let records = try await saved()
        XCTAssertEqual(records.first?.result?.text, "Live tail transcript")
        XCTAssertEqual(records.first?.failure, "Recording cancelled. Audio retained.")
    }

    func testLivePreviewKeepsNativeCancelEnabledThroughoutBuffer() async throws {
        try await setTail(2)
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            $0.id.hasPrefix("deepgram/") && DesktopHostModels.isLive($0.id)
        })
        await toggle(index: index)
        let stopping = Task { await self.toggle(index: index) }
        try await waitForTail()
        effects.live.interim("More tail words")
        for _ in 0..<1_000 {
            if FakeLog.shared.displayedTranscripts.last?.hasSuffix("More tail words") == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(FakeLog.shared.displayedTranscripts.last?.hasSuffix("More tail words"), true)
        XCTAssertEqual(FakeLog.shared.states.last, 2, "Live updates must not restore Stop and hide Cancel.")
        XCTAssertEqual(
            FakeLog.shared.allStatuses.last,
            "Finishing recording buffer. Cancel keeps captured audio without transcription."
        )
        await controller.cancelTranscription()
        await stopping.value
        XCTAssertEqual(effects.live.finishCount, 0)
        XCTAssertTrue(effects.transcriptions.isEmpty)
    }
}
