import Foundation
import SpeakCore
import XCTest
@testable import SpeakAutomationKit

/// `speak say`: where its text comes from, what it asks the app for, and how
/// failures reach a script.
final class CLISpeechTests: XCTestCase {
    private func plan(_ arguments: [String]) throws -> CLIPlan {
        guard case .run(let plan) = try CommandLineParser.parse(arguments) else {
            throw XCTSkip("Expected a runnable plan")
        }
        return plan
    }

    private func run(
        _ arguments: [String], client: StubAutomationClient,
        stdin: Data = Data(), file: Result<Data, Error> = .success(Data())
    ) throws -> CLIOutput {
        let input = CLITextInput(readFile: { _, _ in try file.get() }, readStandardInput: { _ in stdin })
        guard case .finished(let output) = CLIRunner(client: client, version: "9.9.9", textInput: input)
            .run(arguments: arguments) else {
            throw XCTSkip("Expected a finished invocation")
        }
        return output
    }

    // MARK: - Parsing

    func testSay_joinsArgumentsAndPlaysWithTheOnDeviceVoice() throws {
        let plan = try self.plan(["say", "hello", "world"])
        XCTAssertEqual(plan.command, .speakText)
        XCTAssertEqual(plan.speechSource, .inline("hello world"))
        XCTAssertNil(plan.voice)
        XCTAssertNil(plan.path)
        var request = plan.request()
        request.text = "hello world"
        XCTAssertTrue(request.resolvedPlay)
        XCTAssertNil(request.voice)
    }

    func testSay_outputWritesWithoutPlayingUnlessAsked() throws {
        let quiet = try self.plan(["say", "hi", "-o", "out.wav", "--voice", "app"])
        XCTAssertTrue(quiet.path?.hasSuffix("out.wav") == true)
        XCTAssertEqual(quiet.voice, "app")
        XCTAssertFalse(quiet.request().resolvedPlay)

        let both = try self.plan(["say", "hi", "--output=out.m4a", "--play"])
        XCTAssertTrue(both.request().resolvedPlay)
    }

    func testSay_passesTheVoiceSelectionFlags() throws {
        let request = try self.plan([
            "say", "hi", "--provider", "openai", "--model", "tts-1-hd", "--voice", "alloy",
            "--speed", "1.25", "--pitch=-3", "--quality", "high", "--language", "en-US"
        ]).request()
        XCTAssertEqual(request.provider, "openai")
        XCTAssertEqual(request.model, "tts-1-hd")
        XCTAssertEqual(request.voice, "alloy")
        XCTAssertEqual(request.speed, 1.25)
        XCTAssertEqual(request.pitch, -3)
        XCTAssertEqual(request.quality, "high")
        XCTAssertEqual(request.language, "en-US")
        var complete = request
        complete.text = "hi"
        XCTAssertNoThrow(try complete.validated())
    }

    func testSay_rejectsBadSettingValuesBeforeContactingTheApp() {
        for arguments in [["--speed", "fast"], ["--speed", "10"], ["--pitch", "0.5"], ["--quality", "max"],
                          ["--language", "zz-ZZ"], ["--favorite", "Nova"]] {
            XCTAssertThrowsError(try CommandLineParser.parse(["say", "hi"] + arguments), "\(arguments)")
        }
    }

    func testVoices_listsWithMarkersAndModels() throws {
        let plan = try self.plan(["voices", "--provider", "openai", "--json"])
        XCTAssertEqual(plan.command, .listVoices)
        XCTAssertEqual(plan.provider, "openai")
        XCTAssertThrowsError(try CommandLineParser.parse(["voices", "--voice", "x"]))

        var reply = AutomationResult()
        reply.voices = [
            AutomationVoice(id: "openai/alloy", name: "Alloy", provider: "openai", providerName: "OpenAI",
                            models: ["openai/tts-1", "openai/tts-1-hd"], model: "openai/tts-1", selected: true),
            AutomationVoice(id: "system/default", name: "System default", provider: "system",
                            providerName: "macOS System", onDevice: true)
        ]
        let output = try self.run(["voices"], client: StubAutomationClient(result: reply))
        XCTAssertEqual(output.stdout, """
        * openai/alloy    Alloy (OpenAI)
              models: openai/tts-1 (default), openai/tts-1-hd
          system/default  System default (macOS System)

        """)
    }

    func testSay_printsAFallbackNoticeOnStandardError() throws {
        var reply = AutomationResult()
        reply.notice = "Used the on-device voice."
        let output = try self.run(["say", "hi"], client: StubAutomationClient(result: reply))
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(output.stderr, "note: Used the on-device voice.\n")
    }

    func testSay_readsStandardInputByDefaultOrForDash() throws {
        XCTAssertEqual(try self.plan(["say"]).speechSource, .standardInput)
        XCTAssertEqual(try self.plan(["say", "-"]).speechSource, .standardInput)
        XCTAssertEqual(try self.plan(["say", "-f", "-"]).speechSource, .standardInput)
        XCTAssertEqual(try self.plan(["say", "--file", "notes.txt"]).speechSource, .file("notes.txt"))
    }

    func testSay_doubleDashSpeaksTextThatStartsWithADash() throws {
        XCTAssertEqual(try self.plan(["say", "--", "-5", "degrees"]).speechSource, .inline("-5 degrees"))
    }

    func testSay_rejectsTextWithAFileAndUnsupportedFormats() {
        XCTAssertThrowsError(try CommandLineParser.parse(["say", "-f", "notes.txt", "extra"]))
        XCTAssertThrowsError(try CommandLineParser.parse(["say", "hi", "-o", "out.ogg"])) { error in
            XCTAssertTrue((error as? CLIUsageError)?.message.contains(".wav") == true)
        }
        XCTAssertThrowsError(try CommandLineParser.parse(["say", "hi", "--play=yes"]))
        XCTAssertThrowsError(try CommandLineParser.parse(["listen", "--voice", "app"]))
    }

    func testHelp_documentsSay() {
        XCTAssertTrue(CommandLineParser.usage.contains("speak say"))
        XCTAssertTrue(CommandLineParser.usage.contains("speak voices"))
        XCTAssertTrue(CommandLineParser.usage.contains("--speed"))
        XCTAssertFalse(CommandLineParser.usage.contains("--favorite"))
    }

    // MARK: - Running

    func testSay_sendsStandardInputTextToTheApp() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let output = try self.run(["say", "--voice", "openai/alloy"], client: client, stdin: Data("Read me.\n".utf8))
        XCTAssertEqual(output.exitCode, CLIExitCode.success)
        XCTAssertEqual(output.stdout, "")
        let request = try XCTUnwrap(client.sentRequests.first)
        XCTAssertEqual(request.command, .speakText)
        XCTAssertEqual(request.text, "Read me.\n")
        XCTAssertEqual(request.voice, "openai/alloy")
        XCTAssertNoThrow(try request.validated())
    }

    func testSay_readsAFileAndReportsTheSavedPath() throws {
        var reply = AutomationResult()
        reply.path = "/tmp/out.wav"
        let client = StubAutomationClient(result: reply)
        let output = try self.run(["say", "-f", "notes.txt", "-o", "out.wav"], client: client,
                                  file: .success(Data("From a file".utf8)))
        XCTAssertEqual(output.stdout, "Saved speech to /tmp/out.wav.\n")
        XCTAssertEqual(client.sentRequests.first?.text, "From a file")
    }

    func testSay_failsBeforeContactingTheAppForUnusableInput() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let empty = try self.run(["say"], client: client, stdin: Data(" \n".utf8))
        XCTAssertEqual(empty.exitCode, CLIExitCode.failed)
        XCTAssertTrue(empty.stderr.contains("no text to speak"))

        let binary = try self.run(["say"], client: client, stdin: Data([0xFF, 0xFE, 0xFD]))
        XCTAssertTrue(binary.stderr.contains("not valid UTF-8"))

        let huge = Data(repeating: 0x61, count: CLIRunner.maxSpeechInputBytes + 1)
        let oversized = try self.run(["say"], client: client, stdin: huge)
        XCTAssertTrue(oversized.stderr.contains("too long"))

        let missing = try self.run(["say", "-f", "gone.txt"], client: client,
                                   file: .failure(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(missing.stderr.contains("Could not read text from gone.txt"))
        XCTAssertTrue(client.sentRequests.isEmpty)
    }

    func testSay_againstAnAppWithoutSpeech_asksForAnUpdate() throws {
        let client = StubAutomationClient(
            failure: AutomationError(code: .invalidArgument, message: "Malformed automation request.")
        )
        let output = try self.run(["say", "hi", "--json"], client: client)
        XCTAssertEqual(output.exitCode, CLIExitCode.failed)
        XCTAssertTrue(output.stdout.contains("unsupported_command"))
        XCTAssertTrue(output.stdout.contains("Update the app"))
    }

    // MARK: - MCP

    func testSpeakTextTool_forwardsTextVoiceAndPlay() throws {
        let client = StubAutomationClient(result: AutomationResult())
        let handler = MCPRequestHandler(client: client, version: "9.9.9")
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "speak_text", "arguments": [
                "text": "hello", "voice": "app", "provider": "openai", "model": "tts-1", "play": true
            ]]
        ]
        let line = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: message), encoding: .utf8))
        let reply = try XCTUnwrap(handler.handle(line: line))
        XCTAssertTrue(reply.contains("Spoke the text aloud."))
        let request = try XCTUnwrap(client.sentRequests.first)
        XCTAssertEqual(request.text, "hello")
        XCTAssertEqual(request.voice, "app")
        XCTAssertEqual(request.provider, "openai")
        XCTAssertEqual(request.model, "tts-1")
        XCTAssertEqual(request.play, true)
    }
}
