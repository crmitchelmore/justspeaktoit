import SpeakCore

/// The CLI half of the shared argument surface: which flags each command
/// accepts and the `AutomationToolArguments` field each one sets.
extension CommandLineParser {
    /// The flags each command accepts. With `positionalArgument`, these set
    /// exactly the arguments the command's MCP tool advertises.
    static let options: [AutomationCommand: Set<Option>] = [
        .awaitTranscript: [.json, .timeout, .captureID, .sinceID],
        .startDictation: [.json],
        .stopDictation: [.json],
        .history: [.json, .last],
        .status: [.json],
        .listVoices: [.json, .provider],
        .transcribeFile: [.json, .timeout],
        .speakText: [
            .json, .timeout, .voice, .output, .play, .file, .provider, .model, .speed, .pitch, .quality, .language
        ],
        .getConfiguration: [.json, .prefix],
        .setConfiguration: [.json, .dryRun]
    ]

    /// The argument a command's positional words supply.
    static let positionalArgument: [AutomationCommand: AutomationToolArguments.CodingKeys] = [
        .transcribeFile: .path,
        .speakText: .text,
        .getConfiguration: .keys,
        .setConfiguration: .changes
    ]
}

extension CommandLineParser.Option {
    /// The MCP argument this flag sets, or nil for CLI-only flags.
    var argument: AutomationToolArguments.CodingKeys? {
        switch self {
        case .json, .file: nil
        case .timeout: .timeoutSeconds
        case .last: .limit
        case .captureID: .captureID
        case .sinceID: .sinceID
        case .voice: .voice
        case .output: .path
        case .play: .play
        case .provider: .provider
        case .model: .model
        case .speed: .speed
        case .pitch: .pitch
        case .quality: .quality
        case .language: .language
        case .prefix: .prefix
        case .dryRun: .dryRun
        }
    }
}

extension CLIPlan {
    /// The plan's arguments, under the names MCP `tools/call` uses.
    public var arguments: AutomationToolArguments {
        get {
            var arguments = AutomationToolArguments()
            arguments.path = self.path
            arguments.limit = self.limit
            arguments.timeoutSeconds = self.timeout
            arguments.captureID = self.captureID
            arguments.sinceID = self.sinceID
            arguments.text = self.text
            arguments.voice = self.voice
            arguments.provider = self.provider
            arguments.model = self.model
            arguments.quality = self.quality
            arguments.language = self.language
            arguments.speed = self.speed
            arguments.pitch = self.pitch
            arguments.play = self.play
            arguments.keys = self.keys
            arguments.prefix = self.prefix
            arguments.changes = self.changes
            arguments.dryRun = self.dryRun
            return arguments
        }
        set {
            self.path = newValue.path
            self.limit = newValue.limit
            self.timeout = newValue.timeoutSeconds
            self.captureID = newValue.captureID
            self.sinceID = newValue.sinceID
            self.text = newValue.text
            self.voice = newValue.voice
            self.provider = newValue.provider
            self.model = newValue.model
            self.quality = newValue.quality
            self.language = newValue.language
            self.speed = newValue.speed
            self.pitch = newValue.pitch
            self.play = newValue.play
            self.keys = newValue.keys
            self.prefix = newValue.prefix
            self.changes = newValue.changes
            self.dryRun = newValue.dryRun
        }
    }
}

extension CommandLineParser {
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
                self.applyFlag(option, to: &plan)
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

    private static func applyFlag(_ option: Option, to plan: inout CLIPlan) {
        switch option {
        case .play: plan.play = true
        case .dryRun: plan.dryRun = true
        default: plan.json = true
        }
    }
}
