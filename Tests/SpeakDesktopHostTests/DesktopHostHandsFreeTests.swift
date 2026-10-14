import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import XCTest

final class DesktopHostHandsFreeTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var effects: TailEffects!
    private var index = 0

    override func setUp() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hands-free-\(UUID().uuidString)")
        effects = TailEffects()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil })
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: DesktopHostModels.all[index].id))
        FakeLog.shared.setKey("synthetic", name: provider.apiKeyIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func configure(handsFree: Bool, silence: Bool = false) async throws {
        let configuration = try DesktopConfiguration(values: [
            "handsFreeDictationEnabled": AnyCodable(.bool(handsFree)),
            "silenceDetectionEnabled": AnyCodable(.bool(silence)),
            "silenceDuration": AnyCodable(.double(0.5)),
            "postRecordingTailDuration": AnyCodable(.double(0))
        ])
        try await controller.saveConfiguration(configuration.entries)
    }

    private func shortcut() async {
        await controller.shortcut(.init(
            input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
            target: nil, targetExecutablePath: nil, textOutput: Task { FakeTextOutput() },
            modelIndex: index, deviceID: ""
        ))
    }

    private func manual() async {
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
    }

    private func emit(_ value: Int16, frames: Int = 1, capture: TailCapture) {
        for _ in 0..<frames {
            [Int16](repeating: value, count: 1_600).withUnsafeBufferPointer {
                capture.context.receive($0.baseAddress!, count: $0.count)
            }
        }
    }

    private func wait(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Hands-free lifecycle condition timed out.")
        throw DesktopHostError(message: "Hands-free lifecycle condition timed out.")
    }

    private func records() async throws -> [DesktopRecordingStore.Record] {
        try await controller.store.records()
    }
}

extension DesktopHostHandsFreeTests {
    func testArmedFeedbackReservation_StopsPreviewAndRefusesNewPreviewUntilDisarmed() async throws {
        try await configure(handsFree: true)
        let output = TailFeedbackOutput(captureStops: { 0 }, finishClose: {})
        await controller.prepareRecordingFeedback(loader: TailFeedbackLoader(output: output))
        try await wait { output.ready }
        try await controller.previewRecordingFeedback(.start)
        try await wait { output.events.count == 1 }
        await shortcut()
        XCTAssertGreaterThan(output.stopCount, 0)
        do {
            try await controller.previewRecordingFeedback(.stop)
            XCTFail("Sound preview was admitted while hands-free was listening.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Finish dictation"))
        }
        XCTAssertEqual(output.events.map(\.sound), [.start])
        await shortcut()
        try await controller.previewRecordingFeedback(.stop)
        try await wait { output.events.count == 2 }
        XCTAssertEqual(output.events.map(\.sound), [.start, .stop])
    }

    func testBufferedStartupPCM_PreservesWAVAndUsesHundredMillisecondLiveFrames() throws {
        let rate = 24_000
        let file = try PCMRecordingFile(url: directory.appendingPathComponent("buffered.wav"), sampleRate: rate)
        let client = TailLiveClient()
        let live = DesktopLiveSession(client: client)
        live.start()
        defer { live.cancel() }
        let context = DesktopCaptureContext(file: file, live: live, sampleRate: rate) { _ in
            XCTFail("Buffered PCM persistence failed.")
        }
        context.receiveBuffered(Data(repeating: 0, count: rate * 2 * 3))
        XCTAssertEqual(client.frameSizes, [Int](repeating: rate * 2 / 10, count: 30))
        XCTAssertEqual(try file.finish(), 3, accuracy: 0.0001)
    }

    func testArmingQuietAndDisarming_NeverCreateHistoryOrSecondNativeCapture() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let capture = try XCTUnwrap(effects.capture)
        emit(0, frames: 100, capture: capture)
        let stored = try await records()
        XCTAssertTrue(stored.isEmpty)
        let state = await controller.handsFreeState()
        XCTAssertEqual(state, .armed)
        await shortcut()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.destroyCount, 1)
        emit(2_000, capture: capture)
        try await Task.sleep(for: .milliseconds(10))
        let afterDisarm = try await records()
        XCTAssertTrue(afterDisarm.isEmpty)
    }

    func testSpeechSilenceAndSuccessfulResult_RearmSameNativeCapture() async throws {
        try await configure(handsFree: true, silence: true)
        await shortcut()
        let capture = try XCTUnwrap(effects.capture)
        for _ in 0..<2 {
            emit(2_000, capture: capture)
            try await wait { await self.controller.recording != nil }
            emit(0, frames: 8, capture: capture)
            try await wait { await self.controller.handsFreeState() == .armed }
        }
        let stored = try await records()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.result?.text == "Batch tail transcript" && $0.failure == nil })
        XCTAssertEqual(effects.transcriptions.count, 2)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertEqual(capture.destroyCount, 0)
        XCTAssertTrue(effects.capture === capture)
        await shortcut()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.destroyCount, 1)
    }

    func testDisarmDuringUtterance_KeepsAudioWithoutTranscriptionOrLateRearm() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let capture = try XCTUnwrap(effects.capture)
        emit(2_000, capture: capture)
        try await wait { await self.controller.recording != nil }
        await shortcut()
        emit(0, frames: 10, capture: capture)
        let stored = try await records()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.failure, "Recording cancelled. Audio retained.")
        XCTAssertTrue(effects.transcriptions.isEmpty)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.destroyCount, 1)
        let state = await controller.handsFreeState()
        XCTAssertEqual(state, .off)
    }

    func testManualRecording_StaysManualWhenHandsFreePreferenceIsOn() async throws {
        try await configure(handsFree: true)
        await manual()
        let capture = try XCTUnwrap(effects.capture)
        emit(0, frames: 10, capture: capture)
        let manualRecording = await controller.recording
        let handsFreeState = await controller.handsFreeState()
        XCTAssertNotNil(manualRecording)
        XCTAssertEqual(handsFreeState, .off)
        await manual()
        XCTAssertEqual(effects.transcriptions.count, 1)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testUserAbsence_DisarmsListeningButPreservesManualRecording() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let detector = try XCTUnwrap(effects.capture)
        await controller.handsFreeUserAbsent("Synthetic lock")
        XCTAssertEqual(detector.stopCount, 1)
        let state = await controller.handsFreeState()
        XCTAssertEqual(state, .off)
        await manual()
        let manualCapture = try XCTUnwrap(effects.capture)
        await controller.handsFreeUserAbsent("Synthetic sleep")
        let recording = await controller.recording
        XCTAssertNotNil(recording)
        XCTAssertEqual(manualCapture.stopCount, 0)
        await manual()
    }

    func testConfigurationCommit_DisarmsOnlyAfterSuccessfulPersistence() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let detector = try XCTUnwrap(effects.capture)
        effects.failSettingsWrite = true
        do {
            try await configure(handsFree: false)
            XCTFail("Synthetic write failure must surface.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Synthetic settings write failure"))
        }
        let preserved = await controller.handsFreeState()
        XCTAssertEqual(preserved, .armed)
        XCTAssertEqual(detector.stopCount, 0)
        effects.failSettingsWrite = false
        try await configure(handsFree: false)
        let disarmed = await controller.handsFreeState()
        XCTAssertEqual(disarmed, .off)
        XCTAssertEqual(detector.stopCount, 1)
    }

    func testCommittedConfiguration_PreservesCleanupFailureInFinalStatus() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let detector = try XCTUnwrap(effects.capture)
        detector.failStop = true
        try await configure(handsFree: false)
        let status = try XCTUnwrap(FakeLog.shared.allStatuses.last)
        XCTAssertTrue(status.contains("Hands-free cleanup failed: Synthetic capture stop failed"))
        XCTAssertEqual(detector.destroyCount, 1)
    }

    func testProviderFailure_DisarmsInsteadOfRearming() async throws {
        try await configure(handsFree: true)
        effects.failTranscription = true
        await shortcut()
        let detector = try XCTUnwrap(effects.capture)
        emit(2_000, capture: detector)
        try await wait { await self.controller.recording != nil }
        emit(0, frames: 8, capture: detector)
        try await wait { await self.controller.handsFreeState() == .off }
        let stored = try await records()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored.first?.failure?.contains("Synthetic transcription failure") == true)
        XCTAssertEqual(detector.stopCount, 1)
    }

    func testCancelListening_StopsCaptureAndRejectsLateSpeech() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let detector = try XCTUnwrap(effects.capture)
        await controller.cancelTranscription()
        try await wait { await self.controller.handsFreeState() == .off }
        emit(2_000, capture: detector)
        try await Task.sleep(for: .milliseconds(10))
        let stored = try await records()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(detector.stopCount, 1)
    }

    func testCancelAndHotkeyDuringArming_DoNotCreateCaptureOrLeaveCancellingStatus() async throws {
        try await configure(handsFree: true)
        let playback = await controller.playback
        for useHotkey in [false, true] {
            playback.stopping.hold()
            let arming = Task { await self.shortcut() }
            defer { playback.stopping.release(); arming.cancel() }
            try await wait { await self.controller.handsFreeState() == .arming }
            if useHotkey { await shortcut() } else { await controller.cancelTranscription() }
            playback.stopping.release()
            await arming.value
            let state = await controller.handsFreeState()
            XCTAssertEqual(state, .off)
            XCTAssertNil(effects.capture)
            XCTAssertEqual(FakeLog.shared.states.last, 0)
            XCTAssertEqual(FakeLog.shared.allStatuses.last, "Hands-free arming cancelled.")
        }
    }

    func testManualSilence_ExecutesNormalTranscriptionOnce() async throws {
        try await configure(handsFree: false, silence: true)
        await manual()
        let capture = try XCTUnwrap(effects.capture)
        emit(0, frames: 8, capture: capture)
        try await wait {
            let recording = await self.controller.recording
            let busy = await self.controller.busy
            return recording == nil && !busy
        }
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertEqual(effects.transcriptions.count, 1)
        emit(0, frames: 8, capture: capture)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(effects.transcriptions.count, 1)
    }

    func testNativeFailureAndClose_StopDetectorWithoutLateCapture() async throws {
        try await configure(handsFree: true)
        await shortcut()
        let capture = try XCTUnwrap(effects.capture)
        capture.context.fail("Synthetic device loss")
        try await wait { await self.controller.handsFreeState() == .off }
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.destroyCount, 1)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("Synthetic device loss") })
        await shortcut()
        let replacement = try XCTUnwrap(effects.capture)
        let report = await controller.close()
        XCTAssertTrue(report.handsFreeClosed)
        XCTAssertEqual(replacement.stopCount, 1)
        XCTAssertEqual(replacement.destroyCount, 1)
        emit(2_000, capture: replacement)
        let afterClose = try await records()
        XCTAssertTrue(afterClose.isEmpty)
    }
}
