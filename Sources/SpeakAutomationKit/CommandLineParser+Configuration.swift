import Foundation
import SpeakCore

/// The `speak config get|set` grammar.
extension CommandLineParser {
    static func parseConfig(_ arguments: [String]) throws -> CLIPlan {
        guard let action = arguments.first else {
            throw CLIUsageError(message: "`speak config` needs get or set. Run `speak --help`.")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "get":
            var plan = CLIPlan(command: .getConfiguration)
            let positional = try self.applyOptions(
                &plan, arguments: rest, allowed: self.options[.getConfiguration] ?? [])
            plan.keys = positional.isEmpty ? nil : positional
            return try self.checked(plan)
        case "set":
            var plan = CLIPlan(command: .setConfiguration)
            let positional = try self.applyOptions(
                &plan, arguments: rest, allowed: self.options[.setConfiguration] ?? [])
            guard !positional.isEmpty else {
                throw CLIUsageError(message: "`speak config set` needs at least one key=value.")
            }
            var changes: [String: AnyCodable] = [:]
            for assignment in positional {
                let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else {
                    throw CLIUsageError(message: "Expected key=value (got \"\(assignment)\").")
                }
                let key = String(parts[0])
                guard changes[key] == nil else {
                    throw CLIUsageError(message: "\(key) is set more than once.")
                }
                changes[key] = AnyCodable(self.configurationValue(String(parts[1])))
            }
            plan.changes = changes
            return try self.checked(plan)
        default:
            throw CLIUsageError(message: "Unknown config action \"\(action)\". Use get or set.")
        }
    }

    /// A JSON literal (`true`, `1.2`, `null`, `"text"`, `[...]`, `{...}`), or
    /// otherwise the text itself, so model IDs need no quoting.
    static func configurationValue(_ text: String) -> AnyCodable.JSONValue {
        if let decoded = try? JSONDecoder().decode(AnyCodable.self, from: Data(text.utf8)) {
            return decoded.storage
        }
        return .string(text)
    }

    private static func checked(_ plan: CLIPlan) throws -> CLIPlan {
        do {
            _ = try plan.request().validated()
        } catch let error as AutomationError {
            throw CLIUsageError(message: error.message)
        }
        return plan
    }
}

extension CLIRunner {
    /// `key = value` lines for `config get`, and a change summary for `config set`.
    static func configurationText(for result: AutomationResult, command: AutomationCommand) -> String {
        guard case .object(let object)? = result.configuration?.storage else { return "" }
        if command == .getConfiguration {
            guard case .object(let settings)? = object["settings"], !settings.isEmpty else {
                return "No matching settings.\n"
            }
            var lines = settings.keys.sorted().map { "\($0) = \(Self.render(settings[$0] ?? .null))" }
            if case .object(let apiKeys)? = object["apiKeys"], !apiKeys.isEmpty {
                lines += apiKeys.keys.sorted().map { id in
                    let isSet = apiKeys[id] == .object(["isSet": .bool(true)])
                    return "apiKeys.\(id) = \(isSet ? "set" : "not set")"
                }
            }
            return lines.joined(separator: "\n") + "\n"
        }
        let dryRun = object["dryRun"] == .bool(true)
        var lines: [String] = []
        if case .object(let changes)? = object["changes"], !changes.isEmpty {
            lines.append(dryRun ? "Valid. Would change:" : "Changed:")
            lines += changes.keys.sorted().map { "  \($0) = \(Self.render(changes[$0] ?? .null))" }
        } else {
            lines.append(dryRun ? "Valid. Nothing would change." : "Nothing changed.")
        }
        if case .array(let warnings)? = object["warnings"] {
            lines += warnings.compactMap { if case .string(let text) = $0 { "warning: \(text)" } else { nil } }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ value: AnyCodable.JSONValue) -> String {
        if case .string(let text) = value { return text }
        guard let data = try? JSONEncoder.sortedCompact.encode(AnyCodable(value)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

private extension JSONEncoder {
    static var sortedCompact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
