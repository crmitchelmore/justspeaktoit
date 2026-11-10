import Foundation
import SpeakCore

/// Versioned envelope printed by `--json`.
///
/// Stability contract: fields are only ever added, and `schemaVersion` is bumped
/// if an existing field changes meaning, so scripts can pin behaviour.
public struct CLIJSONEnvelope: Codable, Equatable {
    public let schemaVersion: Int
    public let ok: Bool
    public let command: String
    public let data: AutomationResult?
    public let error: AutomationError?
}

public struct CLIOutput: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CLIOutcome: Equatable {
    case finished(CLIOutput)
    case runMCPServer
}

/// Exit codes are part of the CLI contract: scripts branch on "app not running"
/// (3) versus "you asked for something impossible" (2) versus a real failure (1).
public enum CLIExitCode {
    public static let success: Int32 = 0
    public static let failed: Int32 = 1
    public static let usage: Int32 = 2
    public static let appUnavailable: Int32 = 3
}

/// Reads `speak say` text from a file or standard input, at most `limit` bytes
/// plus one so an oversized input is detected without reading all of it.
public struct CLITextInput {
    public var readFile: (_ path: String, _ limit: Int) throws -> Data
    public var readStandardInput: (_ limit: Int) -> Data

    public init(
        readFile: @escaping (_ path: String, _ limit: Int) throws -> Data,
        readStandardInput: @escaping (_ limit: Int) -> Data
    ) {
        self.readFile = readFile
        self.readStandardInput = readStandardInput
    }

    public static let standard = CLITextInput(
        readFile: { path, limit in
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            return try handle.read(upToCount: limit + 1) ?? Data()
        },
        readStandardInput: { limit in
            (try? FileHandle.standardInput.read(upToCount: limit + 1)) ?? Data()
        }
    )
}

/// Parses arguments, performs the request and renders the result.
public struct CLIRunner {
    private let client: AutomationRequesting
    private let version: String
    private let textInput: CLITextInput

    /// UTF-8 needs at most four bytes per character.
    static let maxSpeechInputBytes = AutomationLimits.maxSpeechCharacters * 4

    public init(client: AutomationRequesting, version: String) {
        self.init(client: client, version: version, textInput: .standard)
    }

    public init(client: AutomationRequesting, version: String, textInput: CLITextInput) {
        self.client = client
        self.version = version
        self.textInput = textInput
    }

    public func run(arguments: [String]) -> CLIOutcome {
        let invocation: CLIInvocation
        do {
            invocation = try CommandLineParser.parse(arguments)
        } catch let error as CLIUsageError {
            return .finished(CLIOutput(
                stderr: "error: \(error.message)\n\n\(CommandLineParser.usage)\n",
                exitCode: CLIExitCode.usage
            ))
        } catch {
            return .finished(CLIOutput(stderr: "error: \(error.localizedDescription)\n",
                                       exitCode: CLIExitCode.usage))
        }

        switch invocation {
        case .help:
            return .finished(CLIOutput(stdout: CommandLineParser.usage + "\n"))
        case .version:
            return .finished(CLIOutput(stdout: "speak \(self.version)\n"))
        case .mcpServer:
            return .runMCPServer
        case .run(var plan):
            do {
                try self.resolveSpeechText(&plan)
            } catch let error as AutomationError {
                return .finished(self.render(error: error, plan: plan))
            } catch {
                return .finished(self.render(
                    error: AutomationError(code: .invalidArgument, message: error.localizedDescription), plan: plan))
            }
            return .finished(self.execute(plan))
        }
    }

    private func resolveSpeechText(_ plan: inout CLIPlan) throws {
        guard let source = plan.speechSource else { return }
        let data: Data
        let origin: String
        switch source {
        case .inline(let text):
            plan.text = text
            return
        case .file(let path):
            origin = URL(fileURLWithPath: path).lastPathComponent
            do {
                data = try self.textInput.readFile(path, Self.maxSpeechInputBytes)
            } catch {
                throw AutomationError(code: .fileNotFound, message: "Could not read text from \(origin).")
            }
        case .standardInput:
            origin = "standard input"
            data = self.textInput.readStandardInput(Self.maxSpeechInputBytes)
        }
        guard data.count <= Self.maxSpeechInputBytes else {
            throw AutomationError(code: .invalidArgument, message: "Text from \(origin) is too long to speak.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutomationError(code: .invalidArgument, message: "Text from \(origin) is not valid UTF-8.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError(code: .invalidArgument, message: "There is no text to speak from \(origin).")
        }
        plan.text = text
    }

    private func execute(_ plan: CLIPlan) -> CLIOutput {
        do {
            let response = try self.client.send(plan.request())
            if response.ok, let result = response.result {
                return self.render(success: result, plan: plan)
            }
            let error = response.error
                ?? AutomationError(code: .internalError, message: "The app reported a failure without a reason.")
            return self.render(error: error, plan: plan)
        } catch let error as AutomationError {
            return self.render(error: error, plan: plan)
        } catch {
            return self.render(
                error: AutomationError(code: .internalError, message: error.localizedDescription),
                plan: plan
            )
        }
    }

    // MARK: - Rendering

    private func render(success result: AutomationResult, plan: CLIPlan) -> CLIOutput {
        guard !plan.json else {
            let envelope = CLIJSONEnvelope(
                schemaVersion: AutomationSchema.currentVersion,
                ok: true,
                command: plan.command.rawValue,
                data: result,
                error: nil
            )
            return CLIOutput(stdout: Self.encode(envelope) + "\n")
        }
        // A notice (such as an on-device fallback) informs a person without
        // changing what a script reads on stdout.
        return CLIOutput(stdout: Self.humanText(for: result, command: plan.command),
                         stderr: result.notice.map { "note: \($0)\n" } ?? "")
    }

    private func render(error original: AutomationError, plan: CLIPlan) -> CLIOutput {
        var error = original
        // An app older than `say` cannot decode the new verb.
        if plan.command == .speakText, error.code == .invalidArgument,
           error.message == "Malformed automation request." {
            error = AutomationError(
                code: .unsupportedCommand,
                message: "This version of Just Speak To It cannot speak text. Update the app and try again."
            )
        }
        let exitCode = error.code == .appUnavailable ? CLIExitCode.appUnavailable : CLIExitCode.failed
        guard !plan.json else {
            let envelope = CLIJSONEnvelope(
                schemaVersion: AutomationSchema.currentVersion,
                ok: false,
                command: plan.command.rawValue,
                data: nil,
                error: error
            )
            // The envelope still goes to stdout on failure so `--json` consumers
            // always parse one stream; the exit code carries the failure.
            return CLIOutput(stdout: Self.encode(envelope) + "\n", exitCode: exitCode)
        }
        return CLIOutput(stderr: "error: \(error.message)\n", exitCode: exitCode)
    }

    static func humanText(for result: AutomationResult, command: AutomationCommand) -> String {
        switch command {
        case .transcribeFile, .stopDictation, .awaitTranscript:
            let text = result.text ?? ""
            return text.isEmpty ? "" : text + "\n"
        case .startDictation:
            return "Dictation started.\n"
        case .speakText:
            return result.path.map { "Saved speech to \($0).\n" } ?? ""
        case .listVoices:
            return Self.voiceTable(result.voices ?? [])
        case .status:
            let version = result.appVersion.map { " \($0)" } ?? ""
            let state = (result.sessionActive ?? false) ? "dictating" : "idle"
            return "Just Speak To It\(version) is running (\(state)).\n"
        case .history:
            let entries = result.entries ?? []
            guard !entries.isEmpty else { return "No transcriptions yet.\n" }
            let formatter = ISO8601DateFormatter()
            return entries
                .map { "\(formatter.string(from: $0.createdAt))  \($0.text)" }
                .joined(separator: "\n") + "\n"
        }
    }

    /// One voice per line: markers, ID, name and provider, then its models.
    static func voiceTable(_ voices: [AutomationVoice]) -> String {
        guard !voices.isEmpty else { return "No usable voices. Choose one and save its key in the app.\n" }
        let width = min(voices.map(\.id.count).max() ?? 0, 48)
        return voices.map { voice in
            let mark = voice.selected ? "*" : " "
            let padded = voice.id.padding(toLength: max(width, voice.id.count), withPad: " ", startingAt: 0)
            var line = "\(mark) \(padded)  \(voice.name) (\(voice.providerName))"
            if !voice.models.isEmpty {
                let models = voice.models.map { $0 == voice.model ? "\($0) (default)" : $0 }
                line += "\n      models: " + models.joined(separator: ", ")
            }
            return line
        }.joined(separator: "\n") + "\n"
    }

    static func encode(_ envelope: CLIJSONEnvelope) -> String {
        guard let data = try? AutomationCoding.encoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else {
            let fields = [
                "\"schemaVersion\":\(AutomationSchema.currentVersion)",
                "\"ok\":false",
                "\"command\":\"\(envelope.command)\"",
                "\"error\":{\"code\":\"internal_error\","
                    + "\"message\":\"Could not encode the response.\"}"
            ]
            return "{" + fields.joined(separator: ",") + "}"
        }
        return text
    }
}
