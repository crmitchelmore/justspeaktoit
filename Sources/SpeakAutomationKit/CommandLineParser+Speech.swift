import Foundation
import SpeakCore

/// The `speak say` grammar: text from arguments, a file or standard input.
extension CommandLineParser {
    static func parseSay(_ arguments: [String]) throws -> CLIPlan {
        var plan = CLIPlan(command: .speakText)
        let positional = try self.applyOptions(&plan, arguments: arguments, allowed: self.options[.speakText] ?? [])
        if plan.speechSource != nil {
            guard positional.isEmpty else {
                throw CLIUsageError(message: "`speak say` takes text or --file, not both.")
            }
        } else if positional.isEmpty || positional == ["-"] {
            plan.speechSource = .standardInput
        } else {
            plan.speechSource = .inline(positional.joined(separator: " "))
        }
        return plan
    }

    static func applySpeech(option: Option, value: String, to plan: inout CLIPlan) throws {
        switch option {
        case .voice, .provider, .model:
            try self.applyVoiceSelection(option: option, value: value, to: &plan)
        case .speed, .pitch, .quality, .language:
            try self.applySpeechSetting(option: option, value: value, to: &plan)
        case .output:
            guard !value.isEmpty else { throw CLIUsageError(message: "--output requires a file path.") }
            do { _ = try AutomationRequestPolicy.speechFormat(forPath: value) } catch let error as AutomationError {
                throw CLIUsageError(message: error.message)
            }
            plan.path = self.absolutePath(for: value)
        case .file:
            guard !value.isEmpty else { throw CLIUsageError(message: "--file requires a text file path.") }
            plan.speechSource = value == "-" ? .standardInput : .file(value)
        default:
            break
        }
    }

    /// Fails fast on values no voice accepts; the app then checks them
    /// against the chosen voice.
    private static func applySpeechSetting(option: Option, value: String, to plan: inout CLIPlan) throws {
        var updated = plan
        switch option {
        case .speed, .pitch:
            guard let number = Double(value) else {
                throw CLIUsageError(message: "\(option.rawValue) must be a number (got \"\(value)\").")
            }
            if option == .speed { updated.speed = number } else { updated.pitch = number }
        case .quality: updated.quality = value
        default: updated.language = value
        }
        do {
            _ = try AutomationSpeechSettings(
                speed: updated.speed, pitch: updated.pitch, quality: updated.quality, language: updated.language)
        } catch let error as AutomationError {
            throw CLIUsageError(message: error.message)
        }
        plan = updated
    }

    private static func applyVoiceSelection(option: Option, value: String, to plan: inout CLIPlan) throws {
        let limit = AutomationLimits.maxVoiceIdentifierLength
        guard !value.isEmpty, value.count <= limit else {
            throw CLIUsageError(message: "\(option.rawValue) must be 1-\(limit) characters.")
        }
        switch option {
        case .provider: plan.provider = value
        case .model: plan.model = value
        default: plan.voice = value
        }
    }
}
