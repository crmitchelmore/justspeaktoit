import Foundation

/// How a `speak_text` request chose its voice. Every field is optional and
/// overrides one app setting; with none, the app's selected voice and model
/// are used, falling back to an on-device voice when nothing is configured.
public struct AutomationSpeechSelection: Equatable, Sendable {
    /// A voice ID or display name, or a keyword below.
    public var voice: String?
    /// A provider ID (`openai`) or display name; alone, picks that provider's
    /// selected or first voice.
    public var provider: String?
    /// A model ID listed by `list_voices` (`openai/tts-1-hd` or `tts-1-hd`);
    /// alone, picks the selected voice if it offers the model, else the first that does.
    public var model: String?

    /// `voice` values with a reserved meaning on the wire.
    public static let appKeyword = "app"
    public static let onDeviceKeyword = "system"

    public init(voice: String? = nil, provider: String? = nil, model: String? = nil) {
        self.voice = voice == Self.appKeyword ? nil : voice
        self.provider = provider
        self.model = model
    }

    /// Asked for the on-device voice rather than a named one.
    public var wantsOnDevice: Bool { self.voice?.lowercased() == Self.onDeviceKeyword }
}

/// Synthesis settings a `speak_text` request overrides for this call only.
/// Nil keeps the app's saved value; nothing here is persisted.
public struct AutomationSpeechSettings: Equatable, Sendable {
    public var speed: Double?
    /// Whole semitones.
    public var pitch: Double?
    public var quality: VoiceSynthesisQuality?
    /// `automatic` or a language ID from the app's voice language list (`en_US`).
    public var language: String?

    public init(
        speed: Double? = nil, pitch: Double? = nil, quality: VoiceSynthesisQuality? = nil, language: String? = nil
    ) {
        self.speed = speed
        self.pitch = pitch
        self.quality = quality
        self.language = language
    }

    public var isEmpty: Bool { self == Self() }

    /// Validates wire values against the shared ranges and catalogues.
    public init(speed: Double?, pitch: Double?, quality: String?, language: String?) throws {
        let speeds = VoiceSynthesisOptions.speedRange
        if let speed, !speed.isFinite || !speeds.contains(speed) {
            throw AutomationError(
                code: .invalidArgument,
                message: "speed must be between \(speeds.lowerBound) and \(speeds.upperBound) (got \(speed))."
            )
        }
        let pitches = VoiceSynthesisOptions.pitchRange
        if let pitch, !pitch.isFinite || !pitches.contains(pitch) || pitch.rounded() != pitch {
            throw AutomationError(
                code: .invalidArgument,
                message: "pitch must be a whole number of semitones from \(Int(pitches.lowerBound)) "
                    + "to \(Int(pitches.upperBound)) (got \(pitch))."
            )
        }
        var parsedQuality: VoiceSynthesisQuality?
        if let quality {
            guard let value = VoiceSynthesisQuality(rawValue: quality.lowercased()) else {
                let options = VoiceSynthesisQuality.allCases.map(\.rawValue).joined(separator: ", ")
                throw AutomationError(
                    code: .invalidArgument, message: "quality must be one of \(options) (got \"\(quality)\")."
                )
            }
            parsedQuality = value
        }
        var parsedLanguage: String?
        if let language {
            var known = VoiceOutputLanguageCatalog.options.map(\.id)
            if !known.contains(VoiceOutputLanguageCatalog.automaticIdentifier) {
                known.insert(VoiceOutputLanguageCatalog.automaticIdentifier, at: 0)
            }
            // Accept en-US as well as the catalogue's en_US.
            let wanted = language.replacingOccurrences(of: "-", with: "_")
            guard let match = known.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "Unknown language \"\(language)\". Use automatic or an ID such as "
                        + known.dropFirst().prefix(4).joined(separator: ", ") + "."
                )
            }
            parsedLanguage = match
        }
        self.init(speed: speed, pitch: pitch, quality: parsedQuality, language: parsedLanguage)
    }

    /// Refuses a speed or pitch the chosen voice cannot apply, rather than
    /// silently ignoring it.
    public func validate(for voice: DesktopSpeechVoice) throws {
        let capabilities = voice.capabilities
        if self.speed != nil, !capabilities.speed {
            throw AutomationError(code: .invalidArgument, message: "\(voice.name) does not support --speed.")
        }
        if let speed, !capabilities.speedRange.contains(speed) {
            let range = capabilities.speedRange
            throw AutomationError(
                code: .invalidArgument,
                message: "\(voice.name) supports speed \(range.lowerBound)–\(range.upperBound) (got \(speed))."
            )
        }
        if self.pitch != nil, !capabilities.pitch {
            throw AutomationError(code: .invalidArgument, message: "\(voice.name) does not support --pitch.")
        }
        if self.quality != nil, !voice.supportsQualityControls {
            throw AutomationError(code: .invalidArgument, message: "\(voice.name) has no quality setting.")
        }
    }
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
    public let settings: AutomationSpeechSettings
    public let output: Output?
    public let play: Bool

    public init(
        text: String, voice: AutomationSpeechSelection, settings: AutomationSpeechSettings = .init(),
        output: Output?, play: Bool
    ) {
        self.settings = settings
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
            guard self.text == nil, self.voice == nil, self.play == nil, self.model == nil, !self.hasSpeechSettings,
                  self.path == nil, self.limit == nil, self.profile == nil else {
                throw AutomationError(code: .invalidArgument, message: "list_voices accepts only a provider.")
            }
        default:
            guard self.text == nil, self.voice == nil, self.play == nil, self.model == nil,
                  !self.hasSpeechSettings else {
                throw AutomationError(code: .invalidArgument, message: "Voice fields require speak_text.")
            }
        }
    }

    private var hasSpeechSettings: Bool {
        self.speed != nil || self.pitch != nil || self.quality != nil || self.language != nil
    }

    func speechSettings() throws -> AutomationSpeechSettings {
        try AutomationSpeechSettings(
            speed: self.speed, pitch: self.pitch, quality: self.quality, language: self.language)
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
        _ = try self.speechSettings()
        for (label, value) in [("voice", self.voice), ("model", self.model), ("provider", self.provider)] {
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
                voice: request.voice, provider: request.provider, model: request.model
            ),
            settings: try request.speechSettings(),
            output: output,
            play: request.resolvedPlay
        )
    }
}
