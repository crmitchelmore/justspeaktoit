import Foundation
import SpeakCore

/// Versioned envelope printed by `--json`.
///
/// Stability contract: fields are only ever added, and `schemaVersion` is bumped
/// if an existing field changes meaning, so scripts can pin behaviour.
public struct CLIJSONEnvelope: Codable, Equatable {
    public let schemaVersion: Int
    public let ok: Bool
    public let command: String
    public let data: AutomationResult?
    public let error: AutomationError?
}

public struct CLIOutput: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CLIOutcome: Equatable {
    case finished(CLIOutput)
    case runMCPServer
}

/// Exit codes are part of the CLI contract: scripts branch on "app not running"
/// (3) versus "you asked for something impossible" (2) versus a real failure (1).
public enum CLIExitCode {
    public static let success: Int32 = 0
    public static let failed: Int32 = 1
    public static let usage: Int32 = 2
    public static let appUnavailable: Int32 = 3
}

/// Parses arguments, performs the request and renders the result.
public struct CLIRunner {
    private let client: AutomationRequesting
    private let version: String

    public init(client: AutomationRequesting, version: String) {
        self.client = client
        self.version = version
    }

    public func run(arguments: [String]) -> CLIOutcome {
        let invocation: CLIInvocation
        do {
            invocation = try CommandLineParser.parse(arguments)
        } catch let error as CLIUsageError {
            return .finished(CLIOutput(
                stderr: "error: \(error.message)\n\n\(CommandLineParser.usage)\n",
                exitCode: CLIExitCode.usage
            ))
        } catch {
            return .finished(CLIOutput(stderr: "error: \(error.localizedDescription)\n",
                                       exitCode: CLIExitCode.usage))
        }

        switch invocation {
        case .help:
            return .finished(CLIOutput(stdout: CommandLineParser.usage + "\n"))
        case .version:
            return .finished(CLIOutput(stdout: "speak \(self.version)\n"))
        case .mcpServer:
            return .runMCPServer
        case .run(let plan):
            return .finished(self.execute(plan))
        }
    }

    private func execute(_ plan: CLIPlan) -> CLIOutput {
        do {
            let response = try self.client.send(plan.request())
            if response.ok, let result = response.result {
                return self.render(success: result, plan: plan)
            }
            let error = response.error
                ?? AutomationError(code: .internalError, message: "The app reported a failure without a reason.")
            return self.render(error: error, plan: plan)
        } catch let error as AutomationError {
            return self.render(error: error, plan: plan)
        } catch {
            return self.render(
                error: AutomationError(code: .internalError, message: error.localizedDescription),
                plan: plan
            )
        }
    }

    // MARK: - Rendering

    private func render(success result: AutomationResult, plan: CLIPlan) -> CLIOutput {
        guard !plan.json else {
            let envelope = CLIJSONEnvelope(
                schemaVersion: SpeakAutomationSchemaVersion,
                ok: true,
                command: plan.command.rawValue,
                data: result,
                error: nil
            )
            return CLIOutput(stdout: Self.encode(envelope) + "\n")
        }
        return CLIOutput(stdout: Self.humanText(for: result, command: plan.command))
    }

    private func render(error: AutomationError, plan: CLIPlan) -> CLIOutput {
        let exitCode = error.code == .appUnavailable ? CLIExitCode.appUnavailable : CLIExitCode.failed
        guard !plan.json else {
            let envelope = CLIJSONEnvelope(
                schemaVersion: SpeakAutomationSchemaVersion,
                ok: false,
                command: plan.command.rawValue,
                data: nil,
                error: error
            )
            // The envelope still goes to stdout on failure so `--json` consumers
            // always parse one stream; the exit code carries the failure.
            return CLIOutput(stdout: Self.encode(envelope) + "\n", exitCode: exitCode)
        }
        return CLIOutput(stderr: "error: \(error.message)\n", exitCode: exitCode)
    }

    static func humanText(for result: AutomationResult, command: AutomationCommand) -> String {
        switch command {
        case .transcribeFile, .stopDictation:
            let text = result.text ?? ""
            return text.isEmpty ? "" : text + "\n"
        case .startDictation:
            return "Dictation started.\n"
        case .status:
            let version = result.appVersion.map { " \($0)" } ?? ""
            let state = (result.sessionActive ?? false) ? "dictating" : "idle"
            return "Just Speak To It\(version) is running (\(state)).\n"
        case .history:
            let entries = result.entries ?? []
            guard !entries.isEmpty else { return "No transcriptions yet.\n" }
            let formatter = ISO8601DateFormatter()
            return entries
                .map { "\(formatter.string(from: $0.createdAt))  \($0.text)" }
                .joined(separator: "\n") + "\n"
        }
    }

    static func encode(_ envelope: CLIJSONEnvelope) -> String {
        guard let data = try? AutomationCoding.encoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else {
            let fields = [
                "\"schemaVersion\":\(SpeakAutomationSchemaVersion)",
                "\"ok\":false",
                "\"command\":\"\(envelope.command)\"",
                "\"error\":{\"code\":\"internal_error\","
                    + "\"message\":\"Could not encode the response.\"}"
            ]
            return "{" + fields.joined(separator: ",") + "}"
        }
        return text
    }
}
