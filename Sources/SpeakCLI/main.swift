import Foundation
import SpeakAutomationKit
import SpeakCore

/// `speak` — thin automation client for Just Speak To It.
///
/// Holds no credentials and no provider logic: every command is forwarded to the
/// running app over its local automation socket (a same-user named pipe on
/// Windows).
let arguments = Array(CommandLine.arguments.dropFirst())
#if os(Windows)
let client = WindowsPipeAutomationClient()
#else
let client = UnixSocketAutomationClient()
#endif
let runner = CLIRunner(client: client, version: SpeakCLIVersion.current)

switch runner.run(arguments: arguments) {
case .finished(let output):
    #if os(Windows)
    WindowsConsoleOutput.write(output.stdout, toStandardError: false)
    WindowsConsoleOutput.write(output.stderr, toStandardError: true)
    #else
    if !output.stdout.isEmpty {
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
    }
    if !output.stderr.isEmpty {
        FileHandle.standardError.write(Data(output.stderr.utf8))
    }
    #endif
    exit(output.exitCode)
case .runMCPServer:
    let handler = MCPRequestHandler(client: client, version: SpeakCLIVersion.current)
    MCPStdioServer(handler: handler).serve()
    exit(CLIExitCode.success)
}
