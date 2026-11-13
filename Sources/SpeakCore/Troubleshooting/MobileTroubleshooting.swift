import Foundation

/// The Troubleshooting findings for the phone apps (issue #1634).
///
/// Desktop has `DesktopTroubleshooting`; this is the same idea for iOS and
/// Android, where the things that stop dictation are different: microphone
/// and speech permissions, whether the recogniser can run in the chosen
/// language, whether the selected provider has a key that works, and whether
/// the keyboard is set up. Each platform gathers those facts into ``Input``;
/// every verdict and fix is decided here so the platforms agree.
public enum MobileTroubleshooting {
    public enum Severity: String, Equatable, Sendable, CaseIterable {
        case issue, warning, info, ok

        public var priority: Int {
            switch self {
            case .issue: return 0
            case .warning: return 1
            case .info: return 2
            case .ok: return 3
            }
        }
    }

    public enum Permission: String, Equatable, Sendable {
        case granted, denied, restricted, notDetermined
    }

    /// Whether the recogniser the selected model uses can run right now.
    public enum Recogniser: String, Equatable, Sendable {
        /// The selected model runs on a provider's servers.
        case notRequired
        case ready
        /// Supported for the language, but its model is not on the device yet.
        case needsDownload
        case unsupportedLanguage
        /// Supported, but the system reports it cannot run at the moment.
        case unavailable
        case unknown
    }

    public enum KeyState: String, Equatable, Sendable {
        case notRequired
        case present
        case missing
        /// The provider refused the stored key when it was checked.
        case rejected
        /// The secure store could not be read, so presence is unknown.
        case unreadable
    }

    public enum Keyboard: String, Equatable, Sendable {
        /// This build has no keyboard, so there is nothing to check.
        case notOffered
        case notAdded
        case needsFullAccess
        case ready
    }

    public enum Fix: String, Equatable, Sendable, CaseIterable {
        case requestMicrophone
        case requestSpeechRecognition
        case openSystemSettings
        case openTranscriptionSettings
        case openAPIKeys
        case verifyKey
        case disablePostProcessing
        case openKeyboardSetup

        public var title: String {
            switch self {
            case .requestMicrophone: return "Allow microphone"
            case .requestSpeechRecognition: return "Allow speech recognition"
            case .openSystemSettings: return "Open Settings"
            case .openTranscriptionSettings: return "Transcription settings"
            case .openAPIKeys: return "API keys"
            case .verifyKey: return "Check key"
            case .disablePostProcessing: return "Turn off cleanup"
            case .openKeyboardSetup: return "Keyboard setup"
            }
        }
    }

    public enum Check: String, CaseIterable, Sendable {
        case microphone = "microphone-permission"
        case speechRecognition = "speech-recognition-permission"
        case recogniser
        case transcriptionKey = "transcription-api-key"
        case postProcessingKey = "postprocessing-api-key"
        case keyboard
    }

    public struct Finding: Equatable, Sendable, Identifiable {
        public let check: Check
        public let title: String
        public let detail: String
        public let severity: Severity
        public let fixes: [Fix]
        public let systemImage: String

        public var id: String { check.rawValue }

        public init(
            check: Check, title: String, detail: String, severity: Severity,
            fixes: [Fix] = [], systemImage: String
        ) {
            self.check = check
            self.title = title
            self.detail = detail
            self.severity = severity
            self.fixes = fixes
            self.systemImage = systemImage
        }
    }

    public struct Provider: Equatable, Sendable {
        /// The provider the key belongs to, or nil when no key is needed.
        public let name: String?
        public let key: KeyState
        /// Whether this platform can ask the provider about the key.
        public let canVerify: Bool

        public init(name: String?, key: KeyState, canVerify: Bool = false) {
            self.name = name
            self.key = key
            self.canVerify = canVerify
        }
    }

    public struct Input: Equatable, Sendable {
        public let microphone: Permission
        /// Nil when the selected model does not use the system recogniser.
        public let speechRecognition: Permission?
        public let recogniser: Recogniser
        public let transcription: Provider
        public let postProcessingEnabled: Bool
        public let postProcessing: Provider
        public let keyboard: Keyboard

        public init(
            microphone: Permission,
            speechRecognition: Permission? = nil,
            recogniser: Recogniser = .notRequired,
            transcription: Provider,
            postProcessingEnabled: Bool = false,
            postProcessing: Provider = Provider(name: nil, key: .notRequired),
            keyboard: Keyboard = .notOffered
        ) {
            self.microphone = microphone
            self.speechRecognition = speechRecognition
            self.recogniser = recogniser
            self.transcription = transcription
            self.postProcessingEnabled = postProcessingEnabled
            self.postProcessing = postProcessing
            self.keyboard = keyboard
        }
    }

    /// Every applicable check, problems first. Checks that do not apply (an
    /// on-device model needs no key, a build without a keyboard) are left out
    /// rather than shown as passing.
    public static func findings(_ input: Input) -> [Finding] {
        let findings = Check.allCases.compactMap { finding(for: $0, input) }
        return findings.enumerated().sorted { lhs, rhs in
            lhs.element.severity.priority != rhs.element.severity.priority
                ? lhs.element.severity.priority < rhs.element.severity.priority
                : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The worst severity, which is what a summary line reports.
    public static func overall(_ findings: [Finding]) -> Severity {
        findings.map(\.severity).min { $0.priority < $1.priority } ?? .ok
    }

    private static func finding(for check: Check, _ input: Input) -> Finding? {
        switch check {
        case .microphone:
            return permissionFinding(check, input.microphone)
        case .speechRecognition:
            return input.speechRecognition.map { permissionFinding(check, $0) }
        case .recogniser:
            return recogniserFinding(input.recogniser)
        case .transcriptionKey:
            return keyFinding(check, input.transcription, role: "Transcription")
        case .postProcessingKey:
            guard input.postProcessingEnabled else { return nil }
            return keyFinding(check, input.postProcessing, role: "Cleanup")
        case .keyboard:
            return keyboardFinding(input.keyboard)
        }
    }
}
