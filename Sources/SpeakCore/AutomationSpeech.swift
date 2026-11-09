import Foundation

/// How a `speak_text` request chose its voice. Every field is optional: with
/// none, the app's selected voice and model are used, falling back to an
/// on-device voice when the app has nothing configured.
public struct AutomationSpeechSelection: Equatable, Sendable {
    /// A voice ID or display name, or a keyword below.
    public var voice: String?
    /// A provider ID (`openai`) or display name; alone, picks that provider's best voice.
    public var provider: String?
    /// A model ID listed by `list_voices` (`openai/tts-1-hd` or `tts-1-hd`).
    public var model: String?
    /// The name or ID of a voice saved as a favourite in the app.
    public var favorite: String?

    /// `voice` values with a reserved meaning on the wire.
    public static let appKeyword = "app"
    public static let onDeviceKeyword = "system"

    public init(voice: String? = nil, provider: String? = nil, model: String? = nil, favorite: String? = nil) {
        self.voice = voice == Self.appKeyword ? nil : voice
        self.provider = provider
        self.model = model
        self.favorite = favorite
    }

    /// Asked for the on-device voice rather than a named one.
    public var wantsOnDevice: Bool { self.voice?.lowercased() == Self.onDeviceKeyword }
}

/// A validated `speak_text` request: what to say, with which voice, and where
/// the audio goes. Hosts receive this rather than the raw wire request.
public struct AutomationSpeechRequest: Equatable, Sendable {
    public struct Output: Equatable, Sendable {
        /// The native path exactly as the client resolved it; on Windows,
        /// `url.path` would render a drive path as "/C:/…".
        public let path: String
        public let url: URL
        public let format: VoiceAudioFormat

        public init(path: String, format: VoiceAudioFormat) {
            self.path = path
            self.url = URL(fileURLWithPath: path)
            self.format = format
        }
    }

    public let text: String
    public let voice: AutomationSpeechSelection
    public let output: Output?
    public let play: Bool

    public init(text: String, voice: AutomationSpeechSelection, output: Output?, play: Bool) {
        self.text = text
        self.voice = voice
        self.output = output
        self.play = play
    }
}

extension AutomationLimits {
    /// Text accepted by `speak_text`; matches the app's own voice-output cap.
    public static let maxSpeechCharacters = 100_000
    public static let maxVoiceIdentifierLength = 256
    /// Deadline for speech, which covers provider latency and playback.
    public static let speechTimeout: TimeInterval = 600
    /// Listing can ask each configured provider for its account voices.
    public static let voiceListingTimeout: TimeInterval = 60
}

extension AutomationRequest {
    /// Speech plays aloud unless the caller only asked for a file.
    public var resolvedPlay: Bool { self.play ?? (self.path == nil) }

    /// Validates `speak_text`, and keeps its fields off every other command.
    func validateSpeechFields() throws {
        switch self.command {
        case .speakText:
            try self.validateSpeech()
        case .listVoices:
            guard self.text == nil, self.voice == nil, self.play == nil, self.model == nil, self.favorite == nil,
                  self.path == nil, self.limit == nil, self.profile == nil else {
                throw AutomationError(code: .invalidArgument, message: "list_voices accepts only a provider.")
            }
        default:
            guard self.text == nil, self.voice == nil, self.play == nil, self.model == nil,
                  self.favorite == nil else {
                throw AutomationError(code: .invalidArgument, message: "Voice fields require speak_text.")
            }
        }
    }

    func validateSpeech() throws {
        guard let text = self.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError(code: .invalidArgument, message: "speak_text requires non-empty text.")
        }
        guard text.unicodeScalars.count <= AutomationLimits.maxSpeechCharacters, !text.utf8.contains(0) else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Text must be at most \(AutomationLimits.maxSpeechCharacters) characters with no NUL bytes."
            )
        }
        for (label, value) in [("voice", self.voice), ("model", self.model), ("favorite", self.favorite)] {
            if let value, value.isEmpty || value.count > AutomationLimits.maxVoiceIdentifierLength {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "\(label) must be 1-\(AutomationLimits.maxVoiceIdentifierLength) characters."
                )
            }
        }
        if let path = self.path {
            guard !path.isEmpty, path.count <= AutomationLimits.maxPathLength else {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "Output path must be 1-\(AutomationLimits.maxPathLength) characters."
                )
            }
            _ = try AutomationRequestPolicy.speechFormat(forPath: path)
        }
        guard self.resolvedPlay || self.path != nil else {
            throw AutomationError(code: .invalidArgument, message: "speak_text must play aloud, write a file, or both.")
        }
        guard self.limit == nil, self.profile == nil else {
            throw AutomationError(
                code: .invalidArgument, message: "speak_text accepts text, a voice selection, path and play."
            )
        }
    }
}

extension AutomationRequestPolicy {
    /// The audio format an output path asks for, from its extension.
    public static func speechFormat(forPath path: String) throws -> VoiceAudioFormat {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard let format = VoiceAudioFormat(rawValue: pathExtension) else {
            let supported = VoiceAudioFormat.allCases.map { ".\($0.fileExtension)" }.joined(separator: ", ")
            let name = URL(fileURLWithPath: path).lastPathComponent
            throw AutomationError(
                code: .invalidArgument, message: "Output file must end in one of \(supported) (got \"\(name)\")."
            )
        }
        return format
    }

    /// The validated speech a `speak_text` request names. An output file may
    /// be replaced, but its folder must exist and it must not be a folder.
    public static func speech(
        for request: AutomationRequest,
        fileManager: FileManager = .default
    ) throws -> AutomationSpeechRequest {
        try request.validateSpeech()
        let text = request.text ?? ""
        var output: AutomationSpeechRequest.Output?
        if let path = request.path {
            let url = URL(fileURLWithPath: path)
            #if os(Windows)
            // Foundation renders a drive path's URL as "/C:/…"; check the native path.
            let filePath = path
            let parentPath = path.lastIndex(where: { $0 == "\\" || $0 == "/" })
                .map { String(path[...$0]) } ?? "."
            #else
            let filePath = url.path
            let parentPath = url.deletingLastPathComponent().path
            #endif
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory), isDirectory.boolValue {
                throw AutomationError(code: .invalidArgument, message: "\(url.lastPathComponent) is a folder.")
            }
            guard fileManager.fileExists(atPath: parentPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AutomationError(
                    code: .fileNotFound, message: "The folder for \(url.lastPathComponent) does not exist."
                )
            }
            output = .init(path: path, format: try self.speechFormat(forPath: path))
        }
        return AutomationSpeechRequest(
            text: text,
            voice: AutomationSpeechSelection(
                voice: request.voice, provider: request.provider, model: request.model, favorite: request.favorite
            ),
            output: output,
            play: request.resolvedPlay
        )
    }
}
