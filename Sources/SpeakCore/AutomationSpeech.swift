import Foundation

/// Which voice a `speak_text` request asked for.
public enum AutomationSpeechVoice: Equatable, Sendable {
    /// The host's no-key on-device voice. The wire leaves `voice` unset.
    case onDevice
    /// The voice selected in the app's Voice settings.
    case app
    /// One explicit voice identifier, in the host's own voice catalogue.
    case identifier(String)

    /// `voice` values with a reserved meaning on the wire.
    public static let appKeyword = "app"
    public static let onDeviceKeyword = "system"

    public init(wireValue: String?) {
        switch wireValue {
        case nil, Self.onDeviceKeyword: self = .onDevice
        case Self.appKeyword: self = .app
        case let identifier?: self = .identifier(identifier)
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
    public let voice: AutomationSpeechVoice
    public let output: Output?
    public let play: Bool

    public init(text: String, voice: AutomationSpeechVoice, output: Output?, play: Bool) {
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
}

extension AutomationRequest {
    /// Speech plays aloud unless the caller only asked for a file.
    public var resolvedPlay: Bool { self.play ?? (self.path == nil) }

    /// Validates `speak_text`, and keeps its fields off every other command.
    func validateSpeechFields() throws {
        guard self.command == .speakText else {
            guard self.text == nil, self.voice == nil, self.play == nil else {
                throw AutomationError(code: .invalidArgument, message: "text, voice and play require speak_text.")
            }
            return
        }
        try self.validateSpeech()
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
        if let voice = self.voice, voice.isEmpty || voice.count > AutomationLimits.maxVoiceIdentifierLength {
            throw AutomationError(
                code: .invalidArgument,
                message: "voice must be 1-\(AutomationLimits.maxVoiceIdentifierLength) characters."
            )
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
        guard self.limit == nil, self.profile == nil, self.provider == nil else {
            throw AutomationError(code: .invalidArgument, message: "speak_text accepts text, voice, path and play.")
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
            text: text, voice: AutomationSpeechVoice(wireValue: request.voice), output: output,
            play: request.resolvedPlay
        )
    }
}

extension AutomationError {
    /// A host with no on-device voice asked for the default voice.
    public static func noOnDeviceVoice(platform: String) -> AutomationError {
        AutomationError(
            code: .unsupportedCommand,
            message: "\(platform) has no on-device voice in Just Speak To It yet. Pass --voice app to use "
                + "the voice selected in the app's Voice settings, or --voice <id> for a specific cloud voice."
        )
    }
}
