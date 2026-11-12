#if !APP_STORE
import Foundation

/// The llama.cpp Python runtime behind downloaded GGUF post-processing: its
/// virtual environment, install and probe, and one completion per process.
@MainActor
struct LlamaCppRuntime {
  private let sidecar: LocalPythonSidecar

  init(baseDirectory: URL, runtimeDirectory: URL, fileManager: FileManager) {
    sidecar = LocalPythonSidecar(
      virtualEnvironmentURL: baseDirectory.appendingPathComponent("venv", isDirectory: true),
      scriptURL: runtimeDirectory.appendingPathComponent("local_post_processing.py"),
      script: Self.sidecarScript,
      fileManager: fileManager,
      pythonUnavailable: { LocalPostProcessingModelError.pythonUnavailable }
    )
  }

  func writeScriptIfNeeded() throws {
    try sidecar.writeScriptIfNeeded()
  }

  /// Builds `llama-cpp-python` with Metal into the runtime's own venv.
  func install() async throws {
    let python = try await sidecar.prepareVirtualEnvironment { bootstrapPython, arguments in
      _ = try await Self.runProcess(executableURL: bootstrapPython, arguments: arguments)
    }
    _ = try await Self.runProcess(
      executableURL: python,
      arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel", "cmake", "ninja"]
    )
    _ = try await Self.runProcess(
      executableURL: python,
      arguments: [
        "-m", "pip", "install",
        "llama-cpp-python==0.3.23"
      ],
      environment: [
        "CMAKE_ARGS": "-DGGML_METAL=on"
      ],
      timeout: LocalProcessRunner.runtimeBuildTimeout
    )
    try await ensureAvailable()
  }

  /// Throws unless the venv can import `llama_cpp`.
  func ensureAvailable() async throws {
    let python = try sidecar.pythonExecutable()
    _ = try await Self.runProcess(
      executableURL: python,
      arguments: ["-c", "import llama_cpp; print(getattr(llama_cpp, '__version__', 'ok'))"],
      timeout: LocalProcessRunner.probeTimeout
    )
  }

  /// Runs one chat completion against the GGUF file in a fresh sidecar process.
  func complete(_ request: LocalPostProcessingRequest, modelURL: URL) async throws -> LocalPostProcessingResponse {
    try await ensureAvailable()
    let python = try sidecar.pythonExecutable()
    let script = try sidecar.currentScriptURL()
    let payload = try JSONEncoder().encode(request)
    let output = try await Self.runProcess(
      executableURL: python,
      arguments: [script.path, "--model", modelURL.path],
      standardInput: payload,
      timeout: LocalProcessRunner.inferenceTimeout
    )
    try Task.checkCancellation()
    return try JSONDecoder().decode(LocalPostProcessingResponse.self, from: Data(output.utf8))
  }

  nonisolated static func readableInstallError(from error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.contains("No matching distribution found") || message.contains("Could not find a version") {
      return """
      No compatible llama.cpp Python package was available for this Python version. \
      Try installing Python 3.11 or 3.12, then install the runtime again.
      """
    }
    if message.contains("cmake") || message.contains("CMake") {
      return """
      Building the llama.cpp runtime failed while preparing CMake. \
      Install Xcode Command Line Tools, then try again.
      """
    }
    if message.isEmpty {
      return "The llama.cpp runtime install failed. Check your Python installation and try again."
    }
    return String(message.prefix(500))
  }

  /// Setup failures (no stdin) read as a missing runtime; inference failures
  /// (with stdin) read as a failed post-process.
  private nonisolated static func runProcess(
    executableURL: URL,
    arguments: [String],
    standardInput: Data? = nil,
    environment: [String: String] = [:],
    timeout: TimeInterval = LocalProcessRunner.setupTimeout
  ) async throws -> String {
    do {
      return try await LocalProcessRunner.run(
        executableURL: executableURL,
        arguments: arguments,
        standardInput: standardInput,
        environment: environment,
        timeout: timeout
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw standardInput == nil
        ? LocalPostProcessingModelError.runtimeUnavailable(error.localizedDescription)
        : LocalPostProcessingModelError.processFailed(error.localizedDescription)
    }
  }

  private nonisolated static let sidecarScript = #"""
import argparse
import json
import sys

from llama_cpp import Llama


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    request = json.loads(sys.stdin.read())
    system_prompt = request["systemPrompt"]
    raw_text = request.get("rawText") or ""
    user_prompt = request["userPrompt"]
    temperature = float(request.get("temperature") or 0.2)
    max_tokens = min(8192, max(1024, len(raw_text.split()) * 4 + 512))

    llm = Llama(
        model_path=args.model,
        n_ctx=8192,
        n_threads=None,
        verbose=False,
    )
    response = llm.create_chat_completion(
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=temperature,
        max_tokens=max_tokens,
    )
    choice = response["choices"][0]
    text = choice["message"]["content"]
    print(json.dumps({"text": text, "truncated": choice.get("finish_reason") == "length"}))


if __name__ == "__main__":
    main()
"""#
}

struct LocalPostProcessingRequest: Codable {
  let systemPrompt: String
  let userPrompt: String
  let rawText: String
  let temperature: Double
}

struct LocalPostProcessingResponse: Codable {
  let text: String
  let truncated: Bool?
}
#endif
