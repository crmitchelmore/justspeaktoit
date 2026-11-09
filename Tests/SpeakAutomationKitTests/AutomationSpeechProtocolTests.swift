import Foundation
import SpeakCore
import XCTest

/// The `speak_text` wire contract every host enforces.
final class AutomationSpeechProtocolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func request(text: String? = "Hello", voice: String? = nil, path: String? = nil,
                         play: Bool? = nil) -> AutomationRequest {
        var request = AutomationRequest(command: .speakText, path: path)
        request.text = text
        request.voice = voice
        request.play = play
        return request
    }

    private func assertInvalid(_ request: AutomationRequest, _ fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try request.validated(), file: file, line: line) { error in
            let error = error as? AutomationError
            XCTAssertEqual(error?.code, .invalidArgument, file: file, line: line)
            XCTAssertTrue(error?.message.contains(fragment) == true, error?.message ?? "", file: file, line: line)
        }
    }

    func testValidation_requiresUsableTextAndAnOutcome() {
        self.assertInvalid(self.request(text: nil), "non-empty text")
        self.assertInvalid(self.request(text: "  \n"), "non-empty text")
        self.assertInvalid(self.request(text: "a\u{0}b"), "NUL")
        self.assertInvalid(
            self.request(text: String(repeating: "a", count: AutomationLimits.maxSpeechCharacters + 1)), "at most")
        self.assertInvalid(self.request(play: false), "play aloud, write a file")
        self.assertInvalid(self.request(path: "/tmp/out.flac"), ".wav")
        self.assertInvalid(self.request(voice: ""), "voice must be")
        XCTAssertNoThrow(try self.request().validated())
    }

    func testValidation_keepsSpeechFieldsOffOtherCommands() {
        var status = AutomationRequest(command: .status)
        status.text = "Hello"
        self.assertInvalid(status, "require speak_text")
    }

    func testSpeechDeadline_coversProviderLatencyAndPlayback() {
        XCTAssertEqual(self.request().resolvedTimeout, AutomationLimits.speechTimeout)
    }

    func testSelectionKeywords_mapToTheirMeaning() {
        XCTAssertNil(AutomationSpeechSelection(voice: "app").voice)
        XCTAssertTrue(AutomationSpeechSelection(voice: "System").wantsOnDevice)
        XCTAssertFalse(AutomationSpeechSelection(voice: "openai/alloy").wantsOnDevice)
    }

    func testProvider_isAcceptedOnlyForVoiceCommands() throws {
        var speech = self.request()
        speech.provider = "openai"
        speech.model = "tts-1"
        speech.favorite = "Alloy"
        XCTAssertNoThrow(try speech.validated())

        var list = AutomationRequest(command: .listVoices)
        list.provider = "openai"
        XCTAssertNoThrow(try list.validated())
        list.voice = "x"
        self.assertInvalid(list, "only a provider")

        var status = AutomationRequest(command: .status)
        status.model = "tts-1"
        self.assertInvalid(status, "require speak_text")
    }

    func testPolicy_resolvesTheOutputFormatAndPlayDefault() throws {
        let path = self.directory.appendingPathComponent("Out.M4A").path
        let speech = try AutomationRequestPolicy.speech(for: self.request(voice: "app", path: path))
        XCTAssertEqual(speech.text, "Hello")
        XCTAssertEqual(speech.voice, AutomationSpeechSelection())
        XCTAssertEqual(speech.output?.format, .m4a)
        XCTAssertEqual(speech.output?.path, path)
        XCTAssertFalse(speech.play)
        XCTAssertTrue(try AutomationRequestPolicy.speech(for: self.request()).play)
    }

    func testPolicy_rejectsMissingFoldersAndFolderTargets() throws {
        let missing = self.directory.appendingPathComponent("absent/out.wav").path
        XCTAssertThrowsError(try AutomationRequestPolicy.speech(for: self.request(path: missing))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .fileNotFound)
        }
        let folder = self.directory.appendingPathComponent("folder.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AutomationRequestPolicy.speech(for: self.request(path: folder.path))) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }
    }

    func testDispatcher_handsValidatedSpeechToTheHost() async throws {
        let host = SpeechRecordingHost()
        let response = await AutomationCommandDispatcher.response(to: self.request(voice: "app"), host: host)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.voice, "recorded")
        let speech = await host.speech
        XCTAssertEqual(speech?.voice, AutomationSpeechSelection())
        XCTAssertEqual(speech?.play, true)

        let invalid = await AutomationCommandDispatcher.response(to: self.request(text: ""), host: host)
        XCTAssertEqual(invalid.error?.code, .invalidArgument)
    }

    func testDispatcher_listsVoicesFilteredByProvider() async throws {
        var list = AutomationRequest(command: .listVoices)
        list.provider = "OpenAI"
        let response = await AutomationCommandDispatcher.response(to: list, host: SpeechRecordingHost())
        XCTAssertEqual(response.result?.voices?.map(\.id), ["openai/alloy"])
    }

    func testRequestAndResult_roundTripTheNewFields() throws {
        let request = self.request(voice: "app", path: "/tmp/a.wav", play: true)
        let data = try AutomationCoding.encoder().encode(request)
        XCTAssertEqual(try AutomationCoding.decoder().decode(AutomationRequest.self, from: data), request)

        var result = AutomationResult()
        result.voice = "openai/alloy"
        result.path = "/tmp/a.wav"
        result.notice = "Used the on-device voice."
        result.voices = [AutomationVoice(id: "a", name: "A", provider: "p", providerName: "P", models: ["m"])]
        let decoded = try AutomationCoding.decoder().decode(
            AutomationResult.self, from: AutomationCoding.encoder().encode(result))
        XCTAssertEqual(decoded, result)
    }
}

private actor SpeechRecordingHost: AutomationCommandHost {
    private(set) var speech: AutomationSpeechRequest?

    func automationStatus() async -> AutomationResult { AutomationResult() }
    func automationHistory(limit: Int) async -> [AutomationHistoryEntry] { [] }
    func automationTranscribeFile(at url: URL) async throws -> AutomationResult { AutomationResult() }
    func automationStartDictation() async throws -> AutomationResult { AutomationResult() }
    func automationStopDictation() async throws -> AutomationResult { AutomationResult() }
    func automationVoices() async throws -> [AutomationVoice] {
        [
            AutomationVoice(id: "openai/alloy", name: "Alloy", provider: "openai", providerName: "OpenAI"),
            AutomationVoice(id: "system/default", name: "System default", provider: "system",
                            providerName: "macOS System", onDevice: true)
        ]
    }
    func automationSpeak(_ speech: AutomationSpeechRequest) async throws -> AutomationResult {
        self.speech = speech
        var result = AutomationResult()
        result.voice = "recorded"
        return result
    }
}
