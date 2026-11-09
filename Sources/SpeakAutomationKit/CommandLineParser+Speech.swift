import Foundation
import SpeakCore

/// The `speak say` grammar: text from arguments, a file or standard input.
extension CommandLineParser {
    static func parseSay(_ arguments: [String]) throws -> CLIPlan {
        var plan = CLIPlan(command: .speakText)
        let positional = try self.applyOptions(
            &plan, arguments: arguments, allowed: [.json, .timeout, .voice, .output, .play, .file]
        )
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
        case .voice:
            let limit = AutomationLimits.maxVoiceIdentifierLength
            guard !value.isEmpty, value.count <= limit else {
                throw CLIUsageError(message: "--voice must be 1-\(limit) characters.")
            }
            plan.voice = value
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
}
