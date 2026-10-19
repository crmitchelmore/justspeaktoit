import Foundation

/// Copyable setup text for clients of the app's local automation endpoint.
///
/// Every desktop settings surface shows the same MCP server entry and `speak`
/// commands, built from the path of the installed CLI, so a client configured
/// on one platform reads the same on another. Nothing here carries a key or
/// token: `speak` reaches the running app over the same-user endpoint only.
public enum AutomationClientSetup {
    /// The MCP server entry name, matching the name `speak mcp` reports.
    public static let mcpServerName = "justspeaktoit"

    /// How a path is quoted for the shell a copied command is pasted into.
    public enum Shell: Sendable {
        /// PowerShell, the default Windows terminal shell: single quotes, with
        /// an embedded quote doubled, so `$` and backticks stay literal.
        case powerShell
        /// POSIX shells: single quotes, with an embedded quote closed, escaped
        /// and reopened.
        case posix
    }

    /// A complete MCP client configuration naming `speak mcp` by full path, so
    /// it works whatever PATH the client starts with.
    public static func mcpConfiguration(command: String) -> String {
        """
        {
          "mcpServers": {
            "\(mcpServerName)": {
              "command": \(jsonString(command)),
              "args": ["mcp"]
            }
          }
        }
        """
    }

    /// The Claude Code command that registers the same MCP server.
    public static func claudeCodeCommand(command: String, shell: Shell) -> String {
        "claude mcp add \(mcpServerName) -- \(quoted(command, for: shell)) mcp"
    }

    /// One example per automation verb, each runnable as shown.
    public static func usageExamples(command: String, shell: Shell) -> String {
        let speak = invocation(command, for: shell)
        return [
            "\(speak) status",
            "\(speak) listen",
            "\(speak) stop",
            "\(speak) history --last 5 --json",
            "\(speak) transcribe \(shell == .powerShell ? "'C:\\path\\to\\audio.m4a'" : "~/audio.m4a")",
            "\(speak) --help"
        ].joined(separator: "\n")
    }

    /// A JSON string literal; slashes stay readable in Windows and POSIX paths.
    public static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    /// The path quoted as one shell word.
    public static func quoted(_ value: String, for shell: Shell) -> String {
        switch shell {
        case .powerShell:
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case .posix:
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// PowerShell runs a quoted path only through the call operator.
    static func invocation(_ command: String, for shell: Shell) -> String {
        switch shell {
        case .powerShell: return "& " + quoted(command, for: shell)
        case .posix: return quoted(command, for: shell)
        }
    }
}
