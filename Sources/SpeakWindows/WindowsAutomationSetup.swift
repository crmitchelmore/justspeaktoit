import CWindowsSupport
import Foundation
import SpeakCore
import SpeakWindowsPlatform

/// The text General › CLI and MCP setup shows: the same-user pipe `speak`
/// connects to and copyable commands for the installed CLI. The shared
/// `AutomationClientSetup` builds the commands, so they read as on the Mac.
/// No credential passes through; turning automation on or off stays with
/// `WindowsAutomationSwitch`.
enum WindowsAutomationSetup {
    static func configure() {
        let pipeName = (try? WindowsAutomationPipeServer.defaultPipeName()) ?? ""
        guard let command = cliPath() else {
            _ = jsti_window_set_automation_details(pipeName, "", "", "", "")
            return
        }
        let usage = AutomationClientSetup.usageExamples(command: command, shell: .powerShell)
        let mcp = AutomationClientSetup.mcpConfiguration(command: command)
        let claude = AutomationClientSetup.claudeCodeCommand(command: command, shell: .powerShell)
        _ = jsti_window_set_automation_details(pipeName, command, usage, mcp, claude)
    }

    /// speak.exe beside the app, or the package's CLI execution alias.
    static func cliPath() -> String? {
        var buffer = [CChar](repeating: 0, count: 32_768)
        guard jsti_automation_cli_path(&buffer, buffer.count) == 1 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }
}
