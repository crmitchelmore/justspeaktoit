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
        _ voice: AutomationSpeechSelection = .init(), file: String? = nil, play: Bool = false
    ) -> AutomationSpeechRequest {
        AutomationSpeechRequest(
            text: "Synthetic automation speech", voice: voice,
            output: file.map { .init(path: output.appendingPathComponent($0).path, format: .wav) }, play: play
        )
    }

    private func assertRefused(
        _ request: AutomationSpeechRequest, _ code: AutomationErrorCode, _ fragment: String, line: UInt = #line
    ) async {
        do {
            _ = try await controller.automationSpeak(request)
            XCTFail("Expected a refusal", line: line)
        } catch let error as AutomationError {
            XCTAssertEqual(error.code, code, line: line)
            XCTAssertTrue(error.message.contains(fragment), error.message, line: line)
        } catch { XCTFail("Unexpected \(error)", line: line) }
    }

    func testOnDeviceVoice_IsRefusedClearlyOnThisHost() async {
        await assertRefused(speech(.init(voice: "system"), play: true), .unsupportedCommand, "on-device")
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }

    func testDefaultWithoutAnyKey_ExplainsThereIsNothingToFallBackTo() async {
        FakeLog.shared.reset()
        await assertRefused(speech(play: true), .unsupportedCommand, "No voice is configured")
    }

    func testVoices_ListOnlyKeyedProvidersAndMarkTheSelectedVoice() async throws {
        let voices = try await controller.automationVoices()
        XCTAssertFalse(voices.isEmpty)
        XCTAssertEqual(Set(voices.map(\.provider)), ["deepgram"])
        XCTAssertEqual(voices.filter(\.selected).count, 1)
        XCTAssertFalse(voices.contains(where: \.onDevice))
    }

    func testProviderAndModel_SelectAnotherConfiguredVoice() async throws {
        FakeLog.shared.setKey("openai-key", name: OpenAITTSCatalog.credentialIdentifier)
        let openai = try await controller.automationVoices().filter { $0.provider == "openai" }
        let voice = try XCTUnwrap(openai.first { $0.models.count > 1 })
        let model = try XCTUnwrap(voice.models.last)
        let result = try await controller.automationSpeak(
            speech(.init(voice: voice.id, model: model), file: "openai.wav"))
        XCTAssertEqual(result.voice, voice.id)
        XCTAssertEqual(result.model, model)
        let byProvider = try await controller.automationSpeak(speech(.init(provider: "OpenAI"), file: "p.wav"))
        XCTAssertTrue(openai.contains { $0.id == byProvider.voice })
    }

    func testAppVoice_WritesTheFileWithoutPlaying() async throws {
        let result = try await controller.automationSpeak(speech(file: "out.wav"))
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
        _ = try await controller.automationSpeak(speech(play: true))
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
    }

    func testStopInTheWindow_EndsAutomationSpeechWithAFailure() async throws {
        FakeSpeech.shared.reset(holdingSegments: true)
        let request = speech(play: true)
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
            (speech(.init(voice: "nobody/none")), AutomationErrorCode.invalidArgument),
            (AutomationSpeechRequest(
                text: "Hi", voice: .init(),
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
