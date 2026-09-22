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
    public var limit: Int?
    public var timeout: TimeInterval?
    public var json: Bool

    public init(
        command: AutomationCommand,
        path: String? = nil,
        limit: Int? = nil,
        timeout: TimeInterval? = nil,
        json: Bool = false
    ) {
        self.command = command
        self.path = path
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
      speak transcribe <file> [--json] [--timeout <seconds>]
      speak listen [--json]
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
      All commands talk to the running Just Speak To It app over a \(Self.localTransport),
      so API keys and provider configuration stay in the app. --json prints a
      stable, versioned envelope suitable for scripts and agents.

    EXIT CODES
      0 success   1 command failed   2 usage error   3 app not running
    """

    /// How `speak` reaches the app on this platform, named in the usage text.
    static var localTransport: String {
        #if os(Windows)
        return "local named pipe"
        #else
        return "local socket"
        #endif
    }

    /// Verbs that map straight onto a command plus the options they accept.
    /// Table-driven so adding a verb is data, not another branch.
    private static let verbs: [String: (command: AutomationCommand, options: Set<Option>)] = [
        "listen": (.startDictation, [.json]),
        "stop": (.stopDictation, [.json]),
        "history": (.history, [.json, .last]),
        "status": (.status, [.json])
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
        case "transcribe":
            return .run(try self.parseTranscribe(remaining))
        default:
            guard let entry = self.verbs[verb] else {
                throw CLIUsageError(message: "Unknown command \"\(verb)\". Run `speak --help`.")
            }
            var plan = CLIPlan(command: entry.command)
            try self.rejectPositional(&plan, arguments: remaining, allowed: entry.options, verb: verb)
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

    private enum Option: String, CaseIterable {
        case json = "--json"
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
            // Support --flag=value as well as --flag value. Empty subsequences are
            // kept so `--timeout=` fails as a missing value instead of silently
            // swallowing the next argument.
            let parts = token
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
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

    /// The Windows form of `absolutePath(for:currentDirectory:)`, compiled on every
    /// platform so its rules are tested everywhere.
    ///
    /// Resolves the way the caller's own process would open the path: `/` becomes
    /// `\`, `.` and `..` collapse without climbing above the drive or share,
    /// root-relative (`\audio\clip.m4a`) and drive-relative (`D:clip.m4a`) forms
    /// take the current directory's drive or share, and `\\?\` / `\\.\` device
    /// paths pass through verbatim. A leading `~` expands to the user profile.
    /// Another drive's own current directory is not visible to a process, so
    /// `D:clip.m4a` from a `C:` directory resolves at the root of `D:`.
    static func windowsAbsolutePath(for path: String, currentDirectory: String, homeDirectory: String?) -> String {
        if Self.isWindowsDevicePath(path) { return path }
        var candidate = path.replacingOccurrences(of: "/", with: "\\")
        if let home = homeDirectory, !home.isEmpty, candidate == "~" || candidate.hasPrefix("~\\") {
            candidate = Self.windowsNativeDirectory(home) + candidate.dropFirst()
        }
        let directory = Self.windowsNativeDirectory(currentDirectory)
        let base = Self.windowsRoot(of: directory)

        if candidate.hasPrefix("\\\\") {
            let root = Self.windowsRoot(of: candidate)
            return Self.windowsJoin(root: root.root, components: [root.remainder])
        }
        if let drive = Self.windowsDrive(of: candidate) {
            let rest = String(candidate.dropFirst(2))
            if rest.hasPrefix("\\") {
                return Self.windowsJoin(root: drive, components: [rest])
            }
            // Drive-relative: the current directory when it is on that drive.
            if base.root.caseInsensitiveCompare(drive) == .orderedSame {
                return Self.windowsJoin(root: drive, components: [base.remainder, rest])
            }
            return Self.windowsJoin(root: drive, components: [rest])
        }
        if candidate.hasPrefix("\\") {
            return Self.windowsJoin(root: base.root, components: [candidate])
        }
        return Self.windowsJoin(root: base.root, components: [base.remainder, candidate])
    }

    /// `\\?\…` and `\\.\…` address the Win32 device namespace; Windows does not
    /// normalise them, so neither does the CLI.
    private static func isWindowsDevicePath(_ path: String) -> Bool {
        let prefix = path.prefix(4).replacingOccurrences(of: "/", with: "\\")
        return prefix == "\\\\?\\" || prefix == "\\\\.\\"
    }

    /// Foundation may report a directory as `/C:/Users/…`; the wire carries `C:\Users\…`.
    private static func windowsNativeDirectory(_ directory: String) -> String {
        var native = directory.replacingOccurrences(of: "/", with: "\\")
        if native.hasPrefix("\\"), Self.windowsDrive(of: String(native.dropFirst())) != nil {
            native.removeFirst()
        }
        return native
    }

    /// `X:` for a path starting with a drive letter and colon.
    private static func windowsDrive(of path: String) -> String? {
        let characters = Array(path.prefix(2))
        guard characters.count == 2, characters[1] == ":",
              let letter = characters[0].unicodeScalars.first,
              characters[0].unicodeScalars.count == 1,
              (65...90).contains(letter.value) || (97...122).contains(letter.value) else { return nil }
        return String(characters)
    }

    /// Splits an absolute path into its drive (`C:`) or share (`\\server\share`)
    /// and the rest.
    private static func windowsRoot(of path: String) -> (root: String, remainder: String) {
        if path.hasPrefix("\\\\") {
            let parts = path.dropFirst(2).split(separator: "\\", maxSplits: 2, omittingEmptySubsequences: false)
            let root = "\\\\" + parts.prefix(2).joined(separator: "\\")
            return (root, parts.count > 2 ? String(parts[2]) : "")
        }
        if let drive = Self.windowsDrive(of: path) {
            return (drive, String(path.dropFirst(2)))
        }
        return ("", path)
    }

    /// Joins components under `root`, collapsing `.` and `..` without leaving it.
    private static func windowsJoin(root: String, components: [String]) -> String {
        var resolved: [Substring] = []
        for component in components {
            for part in component.split(separator: "\\") {
                switch part {
                case ".":
                    continue
                case "..":
                    if !resolved.isEmpty { resolved.removeLast() }
                default:
                    resolved.append(part)
                }
            }
        }
        return root + "\\" + resolved.joined(separator: "\\")
    }
}
