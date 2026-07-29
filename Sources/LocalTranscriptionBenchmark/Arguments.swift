import Foundation
import SpeakCore

enum BenchmarkCommand {
    case run(RunArguments)
    case compare(CompareArguments)
}

struct RunArguments {
    let engine: LocalTranscriptionEngine
    let model: String
    let modelSource: String?
    let modelRepo: String?
    let backend: String
    let manifestURL: URL
    let outputURL: URL
    let warmupIterations: Int
    let measuredIterations: Int
}

struct CompareArguments {
    let baselineURL: URL
    let candidateURL: URL
    let evidenceURL: URL
    let outputURL: URL
}

enum ArgumentParser {
    static func parse(_ arguments: [String]) throws -> BenchmarkCommand {
        guard let command = arguments.first else { throw CLIError.usage }
        let options = try parseOptions(Array(arguments.dropFirst()))
        switch command {
        case "run":
            try validate(options: options, allowed: [
                "engine", "model", "model-source", "repo", "backend",
                "manifest", "output", "warmups", "iterations"
            ])
            let engine = LocalTranscriptionEngine(identifier: try required("engine", in: options))
            guard engine == .whisperKit || engine == .transcribeCpp else {
                throw CLIError.invalidValue("--engine must be whisperkit or transcribe.cpp")
            }
            let warmups = try positiveInteger(options["warmups"] ?? "1", name: "warmups", permitsZero: true)
            let iterations = try positiveInteger(options["iterations"] ?? "3", name: "iterations")
            return .run(RunArguments(
                engine: engine,
                model: try required("model", in: options),
                modelSource: options["model-source"],
                modelRepo: options["repo"],
                backend: options["backend"] ?? "auto",
                manifestURL: fileURL(try required("manifest", in: options)),
                outputURL: fileURL(try required("output", in: options)),
                warmupIterations: warmups,
                measuredIterations: iterations
            ))
        case "compare":
            try validate(options: options, allowed: [
                "baseline", "candidate", "evidence", "output"
            ])
            return .compare(CompareArguments(
                baselineURL: fileURL(try required("baseline", in: options)),
                candidateURL: fileURL(try required("candidate", in: options)),
                evidenceURL: fileURL(try required("evidence", in: options)),
                outputURL: fileURL(try required("output", in: options))
            ))
        default:
            throw CLIError.invalidValue("Unknown command: \(command)")
        }
    }

    private static func validate(options: [String: String], allowed: Set<String>) throws {
        if let unsupported = options.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CLIError.invalidValue("Unsupported option for this command: --\(unsupported)")
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw CLIError.usage }
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--"), option.count > 2 else { throw CLIError.usage }
            let name = String(option.dropFirst(2))
            guard options[name] == nil else { throw CLIError.invalidValue("Duplicate option: \(option)") }
            options[name] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private static func required(_ name: String, in options: [String: String]) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw CLIError.invalidValue("Missing --\(name)")
        }
        return value
    }

    private static func positiveInteger(
        _ value: String,
        name: String,
        permitsZero: Bool = false
    ) throws -> Int {
        guard let parsed = Int(value), permitsZero ? parsed >= 0 : parsed > 0 else {
            throw CLIError.invalidValue("--\(name) must be \(permitsZero ? "non-negative" : "positive")")
        }
        return parsed
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }
}

enum CLIError: Error, LocalizedError {
    case usage
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return Self.usageText
        case .invalidValue(let message):
            return "\(message)\n\n\(Self.usageText)"
        }
    }

    static let usageText = """
    Usage:
      local-transcription-benchmark run \\
        --engine <whisperkit|transcribe.cpp> --model <name-or-gguf-path> \\
        --manifest <corpus.json> --output <report.json> \\
        [--repo <hugging-face-repo>] [--model-source <url-or-revision>] \\
        [--backend <auto|cpu|metal>] [--warmups <count>] [--iterations <count>]

      local-transcription-benchmark compare \\
        --baseline <whisperkit-report.json> --candidate <transcribe-cpp-report.json> \\
        --evidence <evidence.json> --output <decision.json>
    """
}
