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
        ]
    ]

    /// The argument a command's positional words supply.
    static let positionalArgument: [AutomationCommand: AutomationToolArguments.CodingKeys] = [
        .transcribeFile: .path,
        .speakText: .text
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
        }
    }
}
