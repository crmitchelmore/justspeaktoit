import Foundation
import SpeakAutomationKit
import SpeakCore

/// `speak` — thin automation client for Just Speak To It.
///
/// Holds no credentials and no provider logic: every command is forwarded to the
/// running app over its local automation socket.
let arguments = Array(CommandLine.arguments.dropFirst())
let client = UnixSocketAutomationClient()
let runner = CLIRunner(client: client, version: SpeakCLIVersion.current)

switch runner.run(arguments: arguments) {
case .finished(let output):
    if !output.stdout.isEmpty {
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
    }
    if !output.stderr.isEmpty {
        FileHandle.standardError.write(Data(output.stderr.utf8))
    }
    exit(output.exitCode)
case .runMCPServer:
    let handler = MCPRequestHandler(client: client, version: SpeakCLIVersion.current)
    MCPStdioServer(handler: handler).serve()
    exit(CLIExitCode.success)
}
