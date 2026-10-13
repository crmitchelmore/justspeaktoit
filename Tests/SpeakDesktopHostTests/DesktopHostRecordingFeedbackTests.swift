import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostRecordingFeedbackTests: XCTestCase {
    private var directory: URL!
    private var effects: TailEffects!
    private var controller: DesktopHostController<FakePlatform>!
    private var batchIndex = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-\(UUID().uuidString)")
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

    private func toggle() async {
        await controller.toggle(
            target: nil, modelIndex: batchIndex, deviceID: "", targetExecutablePath: nil,
            textOutput: FakeTextOutput()
        )
    }

    private func waitForTail() async throws {
        for _ in 0..<1_000 {
            if await controller.recordingTail != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DesktopHostError(message: "Recording tail did not start.")
    }

    private func warmFeedback(close: @escaping @Sendable () async -> Void = {}) async throws -> TailFeedbackOutput {
        let output = TailFeedbackOutput(
            captureStops: { [weak effects] in effects?.capture?.stopCount ?? 0 }, finishClose: close
        )
        await controller.prepareRecordingFeedback(loader: TailFeedbackLoader(output: output))
        for _ in 0..<1_000 {
            if output.ready { return output }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DesktopHostError(message: "Feedback preparation did not finish.")
    }

    func testFeedback_NormalStartAfterCaptureReadyAndStopAfterOwnedTail() async throws {
        try await setTail(0.15)
        let feedback = try await warmFeedback()
        await toggle()
        XCTAssertEqual(feedback.events.map(\.sound), [.start])
        XCTAssertEqual(feedback.events.first?.captureStops, 0)
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        XCTAssertEqual(feedback.events.map(\.sound), [.start])
        await stopping.value
        XCTAssertEqual(feedback.events.map(\.sound), [.start, .stop])
        XCTAssertEqual(feedback.events.last?.captureStops, 1)
        XCTAssertEqual(feedback.events.first?.gain ?? 0, 0.49, accuracy: 0.000_001)
    }

    func testFeedback_StartupFailureCaptureFailureAndCloseDoNotEmitStop() async throws {
        try await setTail(0)
        let feedback = try await warmFeedback()
        effects.failStart = true
        await toggle()
        XCTAssertTrue(feedback.events.isEmpty)
        effects.failStart = false
        await toggle()
        let capture = try XCTUnwrap(effects.capture)
        capture.failStop = true
        await toggle()
        XCTAssertEqual(feedback.events.map(\.sound), [.start])
        await toggle()
        await controller.close()
        XCTAssertEqual(feedback.events.map(\.sound), [.start, .start])
        XCTAssertEqual(feedback.closeCount, 1)
    }

    func testFeedback_CancelDuringTailDoesNotEmitStopAndSettingsWriteIsAtomic() async throws {
        try await setTail(2)
        let feedback = try await warmFeedback()
        await toggle()
        let stopping = Task { await self.toggle() }
        try await waitForTail()
        await controller.cancelTranscription()
        await stopping.value
        XCTAssertEqual(feedback.events.map(\.sound), [.start])
        let invalid = try DesktopConfiguration().entries.enumerated().map { index, value in
            DesktopConfiguration.fields[index].key == "recordingSoundVolume" ? "2" : value
        }
        let path = directory.appendingPathComponent("settings.json")
        let before = try Data(contentsOf: path)
        do {
            try await controller.saveConfiguration(invalid)
            XCTFail("Invalid volume was accepted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Recording sound volume"))
        }
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testFeedback_StalledCloseDoesNotDelayCaptureStopOrSaving() async throws {
        let gate = FeedbackCloseGate()
        _ = try await warmFeedback { await gate.wait() }
        await toggle()
        let capture = try XCTUnwrap(effects.capture)
        let report = await controller.close()
        await gate.release()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertTrue(report.recordingSaved)
        XCTAssertFalse(report.recordingFeedbackClosed)
    }
}

private struct TailFeedbackLoader: DesktopRecordingFeedbackLoader {
    let output: TailFeedbackOutput
    func prepare(profile: RecordingFeedbackProfile) async throws -> any DesktopRecordingFeedbackOutput { output }
}

private final class TailFeedbackOutput: DesktopRecordingFeedbackOutput, @unchecked Sendable {
    struct Event {
        let sound: RecordingFeedbackSound
        let gain: Float
        let captureStops: Int
    }
    private let lock = NSLock()
    private let captureStops: @Sendable () -> Int
    private let finishClose: @Sendable () async -> Void
    private var prepared = false
    private var played: [Event] = []
    private var closes = 0
    var ready: Bool { lock.withLock { prepared } }
    var events: [Event] { lock.withLock { played } }
    var closeCount: Int { lock.withLock { closes } }

    init(captureStops: @escaping @Sendable () -> Int, finishClose: @escaping @Sendable () async -> Void) {
        self.captureStops = captureStops
        self.finishClose = finishClose
    }
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) { lock.withLock { prepared = true } }
    func play(_ sound: RecordingFeedbackSound, gain: Float) throws {
        let stops = captureStops()
        lock.withLock { played.append(Event(sound: sound, gain: gain, captureStops: stops)) }
    }
    func stop() {}
    func close() async throws {
        lock.withLock { closes += 1 }
        await finishClose()
    }
}

private actor FeedbackCloseGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
