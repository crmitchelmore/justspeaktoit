import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

/// `speak say` against the shared Windows/Linux host: the Voice settings'
/// providers and keys, the window's playback, and clear refusals.
final class DesktopHostAutomationSpeechTests: XCTestCase {
    private var directory: URL!
    private var output: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-speech-\(UUID())")
        output = FileManager.default.temporaryDirectory.appendingPathComponent("automation-speech-out-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        FakeLog.shared.setKey("deepgram-key", name: VoiceOutputProvider.deepgram.apiKeyIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: output)
    }

    private func speech(
        _ voice: AutomationSpeechVoice, file: String? = nil, play: Bool = false
    ) -> AutomationSpeechRequest {
        AutomationSpeechRequest(
            text: "Synthetic automation speech", voice: voice,
            output: file.map { .init(path: output.appendingPathComponent($0).path, format: .wav) }, play: play
        )
    }

    func testDefaultVoice_FailsClearlyWithoutAnOnDeviceVoice() async {
        do {
            _ = try await controller.automationSpeak(speech(.onDevice, play: true))
            XCTFail("Expected the on-device voice to be refused")
        } catch let error as AutomationError {
            XCTAssertEqual(error.code, .unsupportedCommand)
            XCTAssertTrue(error.message.contains("--voice app"))
        } catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }

    func testAppVoice_WritesTheFileWithoutPlaying() async throws {
        let result = try await controller.automationSpeak(speech(.app, file: "out.wav"))
        let target = output.appendingPathComponent("out.wav")
        let wav = try Data(contentsOf: target)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(result.path, target.path)
        XCTAssertNotNil(result.voice)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    func testAppVoice_PlaysToTheEndThroughTheSharedPlayer() async throws {
        _ = try await controller.automationSpeak(speech(.app, play: true))
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
    }

    func testStopInTheWindow_EndsAutomationSpeechWithAFailure() async throws {
        FakeSpeech.shared.reset(holdingSegments: true)
        let request = speech(.app, play: true)
        let speaking = Task { try await self.controller.automationSpeak(request) }
        for _ in 0..<200 where !FakeSpeech.shared.events.contains("play") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await controller.playbackStop()
        FakeSpeech.shared.releaseSegments()
        do {
            _ = try await speaking.value
            XCTFail("Expected Stop to end the speech")
        } catch let error as AutomationError {
            XCTAssertEqual(error.code, .speechFailed)
        }
        let operations = await controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    func testUnknownVoiceAndProtectedPath_AreRefusedBeforeSynthesis() async {
        for (request, code) in [
            (speech(.identifier("nobody/none")), AutomationErrorCode.invalidArgument),
            (AutomationSpeechRequest(
                text: "Hi", voice: .app,
                output: .init(path: directory.appendingPathComponent("x.wav").path, format: .wav), play: false
            ), .invalidArgument)
        ] {
            do {
                _ = try await controller.automationSpeak(request)
                XCTFail("Expected a refusal")
            } catch let error as AutomationError {
                XCTAssertEqual(error.code, code)
            } catch { XCTFail("Unexpected \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("x.wav").path))
    }
}
