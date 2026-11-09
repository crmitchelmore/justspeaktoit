import Foundation
import SpeakCore

/// What the user asked the `speak` binary to do.
///
/// Parsing is separated from execution so argument handling is testable without
/// a running app or a socket.
public enum CLIInvocation: Equatable {
    case help
    case version
    case mcpServer
    case run(CLIPlan)
}

/// Where `speak say` reads its text. Files and standard input are read by the
/// runner, not the parser, so parsing stays free of I/O.
public enum CLISpeechSource: Equatable {
    case inline(String)
    case file(String)
    case standardInput
}

/// A validated, transport-agnostic description of one CLI command.
public struct CLIPlan: Equatable {
    public var command: AutomationCommand
    public var path: String?
    public var limit: Int?
    public var timeout: TimeInterval?
    public var captureID: String?
    public var sinceID: String?
    public var json: Bool
    public var speechSource: CLISpeechSource?
    public var text: String?
    public var voice: String?
    public var play: Bool?
    public var provider: String?
    public var model: String?
    public var favorite: String?

    public init(
        command: AutomationCommand,
        path: String? = nil,
        limit: Int? = nil,
        timeout: TimeInterval? = nil,
        json: Bool = false
    ) {
        self.init(command: command, path: path, limit: limit, timeout: timeout, json: json, captureID: nil)
    }

    public init(command: AutomationCommand, path: String? = nil, limit: Int? = nil,
                timeout: TimeInterval? = nil, json: Bool = false, captureID: String?, sinceID: String? = nil) {
        self.captureID = captureID
        self.sinceID = sinceID
        self.command = command
        self.path = path
        self.limit = limit
        self.timeout = timeout
        self.json = json
    }

    /// Builds the wire request. The id is injected so a retry can reuse one and
    /// tests can assert on a fixed value.
    public func request(id: String = UUID().uuidString) -> AutomationRequest {
        var request = AutomationRequest(
            id: id,
            command: self.command,
            path: self.path,
            limit: self.limit,
            timeout: self.timeout,
            captureID: self.captureID,
            sinceID: self.sinceID
        )
        request.text = self.text
        request.voice = self.voice
        request.play = self.play
        request.provider = self.provider
        request.model = self.model
        request.favorite = self.favorite
        return request
    }
}

public struct CLIUsageError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Hand-rolled parser for the `speak` grammar.
///
/// Deliberately dependency-free: the CLI must stay a thin binary that ships in
/// the app bundle and via Homebrew without adding packages to the app graph.
public enum CommandLineParser {
    public static let usage = """
    speak — automation CLI for Just Speak To It

    USAGE
      speak transcribe <file> [--json] [--timeout <seconds>]
      speak await --capture-id <uuid> [--since-id <uuid>] [--timeout <seconds>] [--json]
      speak listen [--json]
      speak stop [--json]
      speak history [--last <n>] [--json]
      speak say [<text>... | -f <file> | -] [-o <file>] [--play] [--json]
                [--voice <id|name>] [--provider <id>] [--model <id>] [--favorite <name>]
      speak voices [--provider <id>] [--json]
      speak status [--json]
      speak mcp
      speak --help | --version

    COMMANDS
      transcribe   Transcribe an audio file with the app's configured provider.
      await        Await one identified active local Mac capture; never starts recording.
      listen       Start a dictation session in the running app.
      stop         Stop the active dictation session and print the transcript.
      history      Print the most recent transcriptions (default 10).
      say          Speak text aloud, or save it as audio with -o (.wav, .mp3 or .m4a).
                   Text comes from the arguments, -f <file>, or standard input.
                   Uses the voice and model selected in the app, or the on-device
                   voice when the app has none configured. --voice, --provider,
                   --model and --favorite choose another of the app's voices;
                   --voice system forces the on-device voice. -o writes without
                   playing unless --play is given.
      voices       List the voices say can use: * selected, + favourite.
      status       Report whether the app is reachable and dictating.
      mcp          Run a stdio MCP server exposing the same commands as tools.

    NOTES
      All commands talk to the running Just Speak To It app over a \(Self.localTransport),
      so API keys and provider configuration stay in the app. --json prints a
      stable, versioned envelope suitable for scripts and agents.

    EXIT CODES
      0 success   1 command failed   2 usage error   3 app not running
    """

    /// How `speak` reaches the app on this platform, named in the usage text.
    static var localTransport: String {
        #if os(Windows)
        "local named pipe"
        #else
        "local socket"
        #endif
    }

    /// Verbs that map straight onto a command plus the options they accept.
    /// Table-driven so adding a verb is data, not another branch.
    private static let verbs: [String: (command: AutomationCommand, options: Set<Option>)] = [
        "await": (.awaitTranscript, [.json, .timeout, .captureID, .sinceID]),
        "listen": (.startDictation, [.json]),
        "stop": (.stopDictation, [.json]),
        "history": (.history, [.json, .last]),
        "status": (.status, [.json]),
        "voices": (.listVoices, [.json, .provider])
    ]

    /// Verbs with their own argument grammar.
    private static let customVerbs: [String: ([String]) throws -> CLIPlan] = [
        "transcribe": parseTranscribe,
        "say": parseSay
    ]

    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var remaining = arguments
        guard let verb = remaining.first else { return .help }
        remaining.removeFirst()

        switch verb {
        case "-h", "--help", "help":
            return .help
        case "-v", "--version", "version":
            return .version
        case "mcp":
            guard remaining.isEmpty else {
                throw CLIUsageError(
                    message: "`speak mcp` takes no options (got \(remaining.joined(separator: " ")))."
                )
            }
            return .mcpServer
        default:
            if let custom = self.customVerbs[verb] { return .run(try custom(remaining)) }
            guard let entry = self.verbs[verb] else {
                throw CLIUsageError(message: "Unknown command \"\(verb)\". Run `speak --help`.")
            }
            var plan = CLIPlan(command: entry.command)
            try self.rejectPositional(&plan, arguments: remaining, allowed: entry.options, verb: verb)
            if plan.command == .awaitTranscript {
                do { _ = try plan.request().validated() } catch {
                    throw CLIUsageError(
                        message: "await requires a capture UUID, optional History UUID, and timeout > 0 through 600.")
                }
            }
            return .run(plan)
        }
    }

    private static func parseTranscribe(_ arguments: [String]) throws -> CLIPlan {
        var plan = CLIPlan(command: .transcribeFile)
        let positional = try self.applyOptions(
            &plan,
            arguments: arguments,
            allowed: [.json, .timeout]
        )
        guard let file = positional.first else {
            throw CLIUsageError(message: "`speak transcribe` requires an audio file path.")
        }
        guard positional.count == 1 else {
            throw CLIUsageError(
                message: "`speak transcribe` takes exactly one file path (got \(positional.count))."
            )
        }
        plan.path = self.absolutePath(for: file)
        return plan
    }

    // MARK: - Options

    enum Option: String, CaseIterable {
        case json = "--json"
        case timeout = "--timeout"
        case last = "--last"
        case captureID = "--capture-id"
        case sinceID = "--since-id"
        case voice = "--voice"
        case output = "--output"
        case play = "--play"
        case file = "--file"
        case provider = "--provider"
        case model = "--model"
        case favorite = "--favorite"

        init?(token: String) {
            switch token {
            case "-o": self = .output
            case "-f": self = .file
            default: self.init(rawValue: token)
            }
        }

        var takesValue: Bool {
            self != .json && self != .play
        }
    }

    private static func rejectPositional(
        _ plan: inout CLIPlan,
        arguments: [String],
        allowed: Set<Option>,
        verb: String
    ) throws {
        let positional = try self.applyOptions(&plan, arguments: arguments, allowed: allowed)
        guard positional.isEmpty else {
            throw CLIUsageError(
                message: "`speak \(verb)` takes no positional arguments (got \"\(positional[0])\")."
            )
        }
    }

    /// Applies recognised options to `plan` and returns the positional leftovers.
    static func applyOptions(
        _ plan: inout CLIPlan,
        arguments: [String],
        allowed: Set<Option>
    ) throws -> [String] {
        var positional: [String] = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            index += 1

            // `-` names standard input and `--` ends the options, so text that
            // starts with a dash can still be spoken.
            if token == "--" {
                positional.append(contentsOf: arguments[index...])
                break
            }
            guard token.hasPrefix("-"), token != "-" else {
                positional.append(token)
                continue
            }
            // Support --flag=value as well as --flag value. Empty subsequences are
            // kept so `--timeout=` fails as a missing value instead of silently
            // swallowing the next argument.
            let parts = token
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard let option = Option(token: parts[0]) else {
                throw CLIUsageError(message: "Unknown option \"\(parts[0])\".")
            }
            guard allowed.contains(option) else {
                throw CLIUsageError(message: "\(option.rawValue) is not valid for this command.")
            }
            guard option.takesValue else {
                guard parts.count == 1 else {
                    throw CLIUsageError(message: "\(option.rawValue) does not take a value.")
                }
                if option == .play { plan.play = true } else { plan.json = true }
                continue
            }

            let value: String
            if parts.count == 2 {
                value = parts[1]
            } else {
                guard index < arguments.count else {
                    throw CLIUsageError(message: "\(option.rawValue) requires a value.")
                }
                value = arguments[index]
                index += 1
            }
            try self.apply(option: option, value: value, to: &plan)
        }
        return positional
    }

    private static func apply(option: Option, value: String, to plan: inout CLIPlan) throws {
        switch option {
        case .json, .play:
            break
        case .voice, .output, .file, .provider, .model, .favorite:
            try self.applySpeech(option: option, value: value, to: &plan)
        case .timeout:
            guard let seconds = TimeInterval(value), seconds > 0 else {
                throw CLIUsageError(message: "--timeout must be a positive number of seconds.")
            }
            plan.timeout = seconds
        case .captureID:
            plan.captureID = value
        case .sinceID:
            plan.sinceID = value
        case .last:
            guard let count = Int(value), count >= 1, count <= AutomationLimits.maxHistoryLimit else {
                throw CLIUsageError(
                    message: "--last must be between 1 and \(AutomationLimits.maxHistoryLimit)."
                )
            }
            plan.limit = count
        }
    }

    /// The app resolves paths in its own working directory, so relative paths are
    /// expanded against the caller's cwd before they leave the CLI.
    static func absolutePath(
        for path: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        #if os(Windows)
        return self.windowsAbsolutePath(
            for: path,
            currentDirectory: currentDirectory,
            homeDirectory: ProcessInfo.processInfo.environment["USERPROFILE"]
        )
        #else
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: currentDirectory, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
        #endif
    }
}
