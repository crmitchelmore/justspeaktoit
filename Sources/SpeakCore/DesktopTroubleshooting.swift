import Foundation

public enum DesktopTroubleshooting {
    public enum Severity: String, Equatable, Sendable {
        case ok, info, warning, issue

        public var priority: Int {
            switch self {
            case .issue: return 0
            case .warning: return 1
            case .info: return 2
            case .ok: return 3
            }
        }
    }

    public enum Destination: Equatable, Sendable { case general, apiKeys, shortcuts, permissions }
    public enum Fix: Equatable, Sendable {
        case keepTranscriptOnClipboard, disablePostProcessing

        public var title: String {
            switch self {
            case .keepTranscriptOnClipboard: return "Keep transcript"
            case .disablePostProcessing: return "Disable cleanup"
            }
        }
    }
    public enum Credential: Equatable, Sendable { case available, missing, unavailable }
    public enum Check: String, CaseIterable, Sendable {
        case postProcessing = "postprocessing-api-key"
        case shortcut = "hotkey-info"
        case clipboard = "clipboard-restore"
    }

    public struct Finding: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let severity: Severity
        public let destination: Destination
        public let fix: Fix?
        public let systemImage: String

        // swiftlint:disable:next function_parameter_count
        public init(
            id: String, title: String, detail: String, severity: Severity,
            destination: Destination, fix: Fix? = nil, systemImage: String
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.severity = severity
            self.destination = destination
            self.fix = fix
            self.systemImage = systemImage
        }
    }

    public struct PostProcessing: Sendable {
        public let enabled: Bool
        public let model: String
        public let credential: Credential

        public init(enabled: Bool, model: String, credential: Credential) {
            self.enabled = enabled
            self.model = model
            self.credential = credential
        }
    }

    public struct Input: Sendable {
        public let postProcessing: PostProcessing
        public let shortcutName: String
        public let shortcutInstructions: String
        public let restoreClipboard: Bool

        public init(
            postProcessing: PostProcessing, shortcutName: String,
            shortcutInstructions: String, restoreClipboard: Bool
        ) {
            self.postProcessing = postProcessing
            self.shortcutName = shortcutName
            self.shortcutInstructions = shortcutInstructions
            self.restoreClipboard = restoreClipboard
        }
    }

    public static func requiresCredential(enabled: Bool, model: String) -> Bool {
        let model = model.lowercased()
        return enabled && !model.hasPrefix("apple/") && !model.hasPrefix("local/") && model != "on-device"
    }

    /// Permission and hardware findings are supplied by each platform from its observed state.
    public static func findings(_ input: Input) -> [Finding] {
        Check.allCases.compactMap { check in
            switch check {
            case .postProcessing:
                let processing = input.postProcessing
                guard requiresCredential(enabled: processing.enabled, model: processing.model) else { return nil }
                switch processing.credential {
                case .available: return nil
                case .missing:
                    return Finding(
                        id: check.rawValue, title: "Post-Processing Needs an API Key",
                        detail: "Post-processing is enabled and uses \(processing.model), which requires an OpenRouter "
                            + "API key. Add one in API Keys, or disable post-processing if you don't need it.",
                        severity: .issue, destination: .apiKeys, fix: .disablePostProcessing, systemImage: "key"
                    )
                case .unavailable:
                    return Finding(
                        id: check.rawValue, title: "Post-Processing Key Could Not Be Checked",
                        detail: "The saved credential could not be read. Open API Keys and check its status; "
                            + "this does not mean the key is missing.",
                        severity: .warning, destination: .apiKeys, systemImage: "key"
                    )
                }
            case .shortcut:
                return Finding(
                    id: check.rawValue, title: "Shortcut: \(input.shortcutName)",
                    detail: input.shortcutInstructions, severity: .info, destination: .shortcuts,
                    systemImage: "keyboard"
                )
            case .clipboard:
                return Finding(
                    id: check.rawValue,
                    title: input.restoreClipboard ? "Clipboard Is Restored After Paste" : "Clipboard Behaviour",
                    detail: input.restoreClipboard
                        ? "Your clipboard is restored to its previous contents after pasting. If you want to keep "
                            + "transcriptions on your clipboard, turn this off."
                        : "Transcriptions are kept on your clipboard after pasting.",
                    severity: input.restoreClipboard ? .warning : .ok, destination: .general,
                    fix: input.restoreClipboard ? .keepTranscriptOnClipboard : nil, systemImage: "doc.on.clipboard"
                )
            }
        }
    }
}
