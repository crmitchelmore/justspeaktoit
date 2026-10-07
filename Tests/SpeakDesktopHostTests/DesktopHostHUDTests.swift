import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

/// The recording HUD follows one dictation through the shared controller.
final class DesktopHostHUDTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hud-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        batchIndex = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        let model = DesktopHostModels.all[batchIndex].id
        let credential = try XCTUnwrap(DesktopHostModels.provider(for: model)).apiKeyIdentifier
        FakeLog.shared.setKey("synthetic-key", name: credential)
    }

    override func tearDown() async throws {
        await controller?.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    private func start(_ effects: some DesktopHostEffects<FakePlatform>) async throws {
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
    }

    private func toggle(target: String? = "editor") async {
        await controller.toggle(
            target: target, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
    }

    private func waitFor(_ description: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func testADictationWalksThePhasesAndTheOutputFinishesIt() async throws {
        try await start(SyntheticEffects())
        await toggle()
        await toggle()
        try await waitFor("the HUD to finish") { FakeLog.shared.huds.last?.phase.isTerminal == true }
        XCTAssertEqual(FakeLog.shared.huds, [
            .recording(profile: nil), .transcribing(), .delivering(copying: false), .success("Delivered.")
        ])
        XCTAssertEqual(FakeLog.shared.huds.last?.displayDuration, DesktopHUDState.successDisplayDuration)
    }

    func testAFailedTranscriptionFinishesWithItsReason() async throws {
        try await start(GatedEffects(gate: Gate(open: true)))
        await toggle()
        await toggle()
        let last = try XCTUnwrap(FakeLog.shared.huds.last)
        XCTAssertEqual(last.phase, .failure)
        XCTAssertEqual(last.headline, "Transcription failed")
        XCTAssertEqual(last.displayDuration, DesktopHUDState.failureDisplayDuration)
    }

    func testARecordingThatCannotStartSaysWhy() async throws {
        FakeLog.shared.keys = [:]
        try await start(SyntheticEffects())
        await toggle()
        XCTAssertEqual(FakeLog.shared.huds.count, 1)
        XCTAssertEqual(FakeLog.shared.huds.first?.phase, .failure)
        XCTAssertEqual(FakeLog.shared.huds.first?.headline, "Recording could not start")
    }

    func testImportsNeverShowTheHUD() async throws {
        try await start(SyntheticEffects())
        let audio = directory.appendingPathComponent("memo.wav")
        try Data(repeating: 1, count: 64).write(to: audio)
        await controller.importAudio(path: audio.path, modelIndex: batchIndex)
        let saved = try await DesktopRecordingStore(directory: directory.appendingPathComponent("History"))
            .recoverInterruptedRecordings().records
        XCTAssertEqual(saved.first?.result?.text, "Synthetic transcript")
        XCTAssertTrue(FakeLog.shared.huds.isEmpty)
    }

    func testALateOutputNeverFinishesANewerDictation() async throws {
        let effects = BlockingOutputEffects()
        try await start(effects)
        await toggle()
        await toggle()
        try await waitFor("the first output to start") { effects.started }
        XCTAssertEqual(FakeLog.shared.huds.last, .delivering(copying: false))
        await toggle()
        XCTAssertEqual(FakeLog.shared.huds.last, .recording(profile: nil))
        effects.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(FakeLog.shared.huds.last, .recording(profile: nil))
    }

    func testLiveTextKeepsTheLatestWords() {
        let long = String(repeating: "word ", count: 100) + "latest"
        let state = DesktopHUDState.recording(profile: "Email", liveText: long)
        XCTAssertEqual(state.subheadline, "Profile: Email")
        XCTAssertEqual(state.liveText?.count, DesktopHUDState.liveTextLimit)
        XCTAssertEqual(state.liveText?.hasPrefix("…"), true)
        XCTAssertEqual(state.liveText?.hasSuffix("latest"), true)
        XCTAssertNil(DesktopHUDState.recording(profile: nil, liveText: "  ").liveText)
        XCTAssertTrue(state.showsClock)
        XCTAssertFalse(DesktopHUDState.success("Done").showsClock)
    }
}

/// Output blocks until released, like a slow target application.
final class BlockingOutputEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    private let lock = NSLock()
    private var isStarted = false
    private var isReleased = false
    var started: Bool { lock.withLock { isStarted } }
    func release() { lock.withLock { isReleased = true } }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        TranscriptionResult(
            text: "First dictation", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> String {
        lock.withLock { isStarted = true }
        while !lock.withLock({ isReleased }) { Thread.sleep(forTimeInterval: 0.002) }
        return "Delivered late."
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}
