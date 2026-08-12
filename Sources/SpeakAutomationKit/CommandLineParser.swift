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

/// A validated, transport-agnostic description of one CLI command.
public struct CLIPlan: Equatable {
    public var command: AutomationCommand
    public var path: String?
    public var profile: String?
    public var provider: String?
    public var limit: Int?
    public var timeout: TimeInterval?
    public var json: Bool

    public init(
        command: AutomationCommand,
        path: String? = nil,
        profile: String? = nil,
        provider: String? = nil,
        limit: Int? = nil,
        timeout: TimeInterval? = nil,
        json: Bool = false
    ) {
        self.command = command
        self.path = path
        self.profile = profile
        self.provider = provider
        self.limit = limit
        self.timeout = timeout
        self.json = json
    }

    /// Builds the wire request. The id is injected so a retry can reuse one and
    /// tests can assert on a fixed value.
    public func request(id: String = UUID().uuidString) -> AutomationRequest {
        AutomationRequest(
            id: id,
            command: self.command,
            path: self.path,
            profile: self.profile,
            provider: self.provider,
            limit: self.limit,
            timeout: self.timeout
        )
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
      speak transcribe <file> [--json] [--provider <id>] [--profile <name>] [--timeout <seconds>]
      speak listen [--provider <id>] [--profile <name>] [--json]
      speak stop [--json]
      speak history [--last <n>] [--json]
      speak status [--json]
      speak mcp
      speak --help | --version

    COMMANDS
      transcribe   Transcribe an audio file with the app's configured provider.
      listen       Start a dictation session in the running app.
      stop         Stop the active dictation session and print the transcript.
      history      Print the most recent transcriptions (default 10).
      status       Report whether the app is reachable and dictating.
      mcp          Run a stdio MCP server exposing the same commands as tools.

    NOTES
      All commands talk to the running Just Speak To It app over a local socket,
      so API keys and provider configuration stay in the app. --json prints a
      stable, versioned envelope suitable for scripts and agents.

    EXIT CODES
      0 success   1 command failed   2 usage error   3 app not running
    """

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
        case "transcribe":
            return .run(try self.parseTranscribe(remaining))
        case "listen":
            var plan = CLIPlan(command: .startDictation)
            try self.rejectPositional(&plan, arguments: remaining, allowed: [.json, .provider, .profile], verb: verb)
            return .run(plan)
        case "stop":
            var plan = CLIPlan(command: .stopDictation)
            try self.rejectPositional(&plan, arguments: remaining, allowed: [.json], verb: verb)
            return .run(plan)
        case "history":
            var plan = CLIPlan(command: .history)
            try self.rejectPositional(&plan, arguments: remaining, allowed: [.json, .last], verb: verb)
            return .run(plan)
        case "status":
            var plan = CLIPlan(command: .status)
            try self.rejectPositional(&plan, arguments: remaining, allowed: [.json], verb: verb)
            return .run(plan)
        default:
            throw CLIUsageError(message: "Unknown command \"\(verb)\". Run `speak --help`.")
        }
    }

    private static func parseTranscribe(_ arguments: [String]) throws -> CLIPlan {
        var plan = CLIPlan(command: .transcribeFile)
        let positional = try self.applyOptions(
            &plan,
            arguments: arguments,
            allowed: [.json, .provider, .profile, .timeout]
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

    private enum Option: String, CaseIterable {
        case json = "--json"
        case provider = "--provider"
        case profile = "--profile"
        case timeout = "--timeout"
        case last = "--last"

        var takesValue: Bool {
            self != .json
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
    private static func applyOptions(
        _ plan: inout CLIPlan,
        arguments: [String],
        allowed: Set<Option>
    ) throws -> [String] {
        var positional: [String] = []
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            index += 1

            guard token.hasPrefix("-") else {
                positional.append(token)
                continue
            }
            // Support --flag=value as well as --flag value.
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard let option = Option(rawValue: parts[0]) else {
                throw CLIUsageError(message: "Unknown option \"\(parts[0])\".")
            }
            guard allowed.contains(option) else {
                throw CLIUsageError(message: "\(option.rawValue) is not valid for this command.")
            }
            guard option.takesValue else {
                guard parts.count == 1 else {
                    throw CLIUsageError(message: "\(option.rawValue) does not take a value.")
                }
                plan.json = true
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
        case .json:
            plan.json = true
        case .provider:
            plan.provider = try self.nonEmpty(value, option: option)
        case .profile:
            plan.profile = try self.nonEmpty(value, option: option)
        case .timeout:
            guard let seconds = TimeInterval(value), seconds > 0 else {
                throw CLIUsageError(message: "--timeout must be a positive number of seconds.")
            }
            plan.timeout = seconds
        case .last:
            guard let count = Int(value), count >= 1, count <= AutomationLimits.maxHistoryLimit else {
                throw CLIUsageError(
                    message: "--last must be between 1 and \(AutomationLimits.maxHistoryLimit)."
                )
            }
            plan.limit = count
        }
    }

    private static func nonEmpty(_ value: String, option: Option) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= AutomationLimits.maxIdentifierLength else {
            throw CLIUsageError(
                message: "\(option.rawValue) must be 1-\(AutomationLimits.maxIdentifierLength) characters."
            )
        }
        return trimmed
    }

    /// The app resolves paths in its own working directory, so relative paths are
    /// expanded against the caller's cwd before they leave the CLI.
    static func absolutePath(
        for path: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: currentDirectory, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }
}
