import Foundation
import OSLog
import SpeakCore

// swiftlint:disable type_body_length

enum LocalPostProcessingModelError: LocalizedError {
  case pythonUnavailable
  case runtimeUnavailable(String)
  case unknownModel(String)
  case modelNotInstalled(String)
  case invalidHuggingFaceSource(String)
  case downloadFailed(String)
  case processFailed(String)

  var errorDescription: String? {
    switch self {
    case .pythonUnavailable:
      return "Python 3 was not found. Install Python 3 to enable downloaded local post-processing models."
    case .runtimeUnavailable(let details):
      return "llama.cpp local post-processing runtime is not installed. \(details)"
    case .unknownModel(let model):
      return "Unknown local post-processing model: \(model)"
    case .modelNotInstalled(let model):
      return "\(model) has not been downloaded yet. Download it in Settings > Post-processing > Local."
    case .invalidHuggingFaceSource(let details):
      return "Enter a valid Hugging Face GGUF model source. \(details)"
    case .downloadFailed(let details):
      return "Could not download the local post-processing model from Hugging Face. \(details)"
    case .processFailed(let details):
      return "Local post-processing failed. \(details)"
    }
  }
}

@MainActor
final class LocalPostProcessingModelManager: ObservableObject {
  static let shared = LocalPostProcessingModelManager()

  enum InstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    var isInstalled: Bool {
      if case .installed = self { return true }
      return false
    }
  }

  nonisolated static let builtInRulesModelID = "local/post-processing/rules"

  static let recommendedModels: [LocalPostProcessingModel] = [
    LocalPostProcessingModel(
      id: "local/post-processing/qwen2.5-1.5b-instruct-q4",
      displayName: "Qwen2.5 1.5B Instruct Q4",
      repoID: "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
      filename: "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
      approximateSizeMB: 1_050,
      description: "Recommended local LLM for higher-quality cleanup. Larger download, better instruction following."
    ),
    LocalPostProcessingModel(
      id: "local/post-processing/qwen2.5-0.5b-instruct-q4",
      displayName: "Qwen2.5 0.5B Instruct Q4",
      repoID: "bartowski/Qwen2.5-0.5B-Instruct-GGUF",
      filename: "Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
      approximateSizeMB: 397,
      description: "Fast, smaller local model for simple transcript formatting."
    ),
    LocalPostProcessingModel(
      id: "local/post-processing/smollm2-360m-instruct-q4",
      displayName: "SmolLM2 360M Instruct Q4",
      repoID: "bartowski/SmolLM2-360M-Instruct-GGUF",
      filename: "SmolLM2-360M-Instruct-Q4_K_M.gguf",
      approximateSizeMB: 230,
      description: "Smallest recommended download. Best for quick cleanup, with lower quality on complex transcripts."
    )
  ]

  @Published private(set) var runtimeState: InstallState = .notInstalled
  @Published private(set) var modelStates: [String: InstallState] = [:]
  @Published private(set) var importedModels: [LocalPostProcessingModel] = []

  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.github.speakapp", category: "LocalPostProcessing")
  private let baseDirectory: URL
  private let modelsDirectory: URL
  private let runtimeDirectory: URL
  private let sidecarURL: URL
  private let virtualEnvironmentURL: URL
  private let importedModelsURL: URL
  private var pythonExecutableCache: URL?

  private init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    baseDirectory = base
      .appendingPathComponent("SpeakApp", isDirectory: true)
      .appendingPathComponent("LocalModels", isDirectory: true)
      .appendingPathComponent("LocalPostProcessing", isDirectory: true)
    modelsDirectory = baseDirectory.appendingPathComponent("Models", isDirectory: true)
    runtimeDirectory = baseDirectory.appendingPathComponent("runtime", isDirectory: true)
    sidecarURL = runtimeDirectory.appendingPathComponent("local_post_processing.py")
    virtualEnvironmentURL = baseDirectory.appendingPathComponent("venv", isDirectory: true)
    importedModelsURL = baseDirectory.appendingPathComponent("imported-hugging-face-gguf-models.json")
    do {
      try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
      try writeSidecarIfNeeded()
    } catch {
      runtimeState = .failed(error.localizedDescription)
    }
    loadImportedModels()
    refresh()
  }

  var availableModels: [LocalPostProcessingModel] {
    Self.recommendedModels + importedModels
  }

  var availableModelOptions: [ModelCatalog.Option] {
    availableModels.map(\.option)
  }

  func refresh() {
    Task { await refreshRuntimeState() }
    for model in availableModels {
      modelStates[model.id] = modelFileExists(for: model) ? .installed : .notInstalled
    }
  }

  func installState(for modelID: String) -> InstallState {
    modelStates[modelID] ?? .notInstalled
  }

  func isInstalled(_ modelID: String) -> Bool {
    installState(for: modelID).isInstalled
  }

  func model(for modelID: String) -> LocalPostProcessingModel? {
    availableModels.first { $0.id == modelID }
  }

  @discardableResult
  func addHuggingFaceModel(repoID: String, filename: String, approximateSizeMB: Int?) throws -> LocalPostProcessingModel {
    let repoID = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    let filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard repoID.split(separator: "/").count == 2 else {
      throw LocalPostProcessingModelError.invalidHuggingFaceSource("Use owner/repo, for example bartowski/Qwen2.5-0.5B-Instruct-GGUF.")
    }
    guard filename.lowercased().hasSuffix(".gguf") else {
      throw LocalPostProcessingModelError.invalidHuggingFaceSource("The file must be a .gguf model file.")
    }

    let model = LocalPostProcessingModel(
      displayName: Self.displayName(repoID: repoID, filename: filename),
      repoID: repoID,
      filename: filename,
      approximateSizeMB: approximateSizeMB ?? Self.approximateSizeMB(from: filename),
      description: "Imported from Hugging Face. Runs locally through the llama.cpp post-processing runtime."
    )
    importedModels.removeAll { $0.id == model.id }
    importedModels.append(model)
    try saveImportedModels()
    modelStates[model.id] = modelFileExists(for: model) ? .installed : .notInstalled
    return model
  }

  func installRuntime() async {
    runtimeState = .installing
    do {
      let bootstrapPython = try bootstrapPythonExecutable()
      if !fileManager.fileExists(atPath: venvPythonURL.path) {
        try await Self.runProcess(
          executableURL: bootstrapPython,
          arguments: ["-m", "venv", virtualEnvironmentURL.path]
        )
      }

      let python = venvPythonURL
      pythonExecutableCache = python
      try await Self.runProcess(
        executableURL: python,
        arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel", "cmake", "ninja"]
      )
      try await Self.runProcess(
        executableURL: python,
        arguments: [
          "-m", "pip", "install",
          "llama-cpp-python==0.3.23",
        ],
        environment: [
          "CMAKE_ARGS": "-DGGML_METAL=on"
        ]
      )
      try await ensureRuntimeAvailable()
      runtimeState = .installed
    } catch {
      runtimeState = .failed(Self.readableRuntimeInstallError(from: error))
    }
  }

  func installModel(_ model: LocalPostProcessingModel) async {
    modelStates[model.id] = .installing
    do {
      let finalURL = modelFileURL(for: model)
      let tempURL = finalURL.deletingLastPathComponent()
        .appendingPathComponent(finalURL.lastPathComponent + ".download")
      if fileManager.fileExists(atPath: tempURL.path) {
        try fileManager.removeItem(at: tempURL)
      }
      try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await downloadFile(repoID: model.repoID, filename: model.filename, to: tempURL)
      if fileManager.fileExists(atPath: finalURL.path) {
        try fileManager.removeItem(at: finalURL)
      }
      try fileManager.moveItem(at: tempURL, to: finalURL)
      modelStates[model.id] = .installed
    } catch {
      modelStates[model.id] = .failed(error.localizedDescription)
    }
  }

  func deleteModel(_ model: LocalPostProcessingModel) {
    do {
      let url = modelFileURL(for: model)
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
      modelStates[model.id] = .notInstalled
    } catch {
      modelStates[model.id] = .failed(error.localizedDescription)
    }
  }

  func process(
    modelID: String,
    rawText: String,
    systemPrompt: String,
    temperature: Double
  ) async throws -> String {
    guard let model = model(for: modelID) else {
      throw LocalPostProcessingModelError.unknownModel(modelID)
    }
    guard isInstalled(model.id) else {
      throw LocalPostProcessingModelError.modelNotInstalled(model.displayName)
    }
    try await ensureRuntimeAvailable()
    let python = try pythonExecutable()
    let script = try sidecarScriptURL()
    let modelURL = modelFileURL(for: model)
    let request = LocalPostProcessingRequest(
      systemPrompt: systemPrompt,
      userPrompt: Self.localUserPrompt(systemPrompt: systemPrompt, rawText: rawText),
      rawText: rawText,
      temperature: temperature
    )
    let payload = try JSONEncoder().encode(request)
    let output = try await Self.runProcess(
      executableURL: python,
      arguments: [script.path, "--model", modelURL.path],
      standardInput: payload
    )
    let response = try JSONDecoder().decode(LocalPostProcessingResponse.self, from: Data(output.utf8))
    guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalPostProcessingModelError.processFailed("The local model returned an empty response.")
    }
    return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func sidecarScriptURL() throws -> URL {
    try writeSidecarIfNeeded()
    return sidecarURL
  }

  func pythonExecutable() throws -> URL {
    if fileManager.isExecutableFile(atPath: venvPythonURL.path) {
      pythonExecutableCache = venvPythonURL
      return venvPythonURL
    }
    if let pythonExecutableCache { return pythonExecutableCache }
    return try bootstrapPythonExecutable()
  }

  private var venvPythonURL: URL {
    virtualEnvironmentURL
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("python3")
  }

  private func bootstrapPythonExecutable() throws -> URL {
    let candidates = [
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/usr/bin/python3",
    ]
    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
      let url = URL(fileURLWithPath: candidate)
      pythonExecutableCache = url
      return url
    }
    throw LocalPostProcessingModelError.pythonUnavailable
  }

  private func refreshRuntimeState() async {
    do {
      try await ensureRuntimeAvailable()
      runtimeState = .installed
    } catch {
      runtimeState = .notInstalled
    }
  }

  private func ensureRuntimeAvailable() async throws {
    let python = try pythonExecutable()
    _ = try await Self.runProcess(
      executableURL: python,
      arguments: ["-c", "import llama_cpp; print(getattr(llama_cpp, '__version__', 'ok'))"]
    )
  }

  private func modelFileExists(for model: LocalPostProcessingModel) -> Bool {
    fileManager.fileExists(atPath: modelFileURL(for: model).path)
  }

  private func modelFileURL(for model: LocalPostProcessingModel) -> URL {
    modelsDirectory
      .appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
      .appendingPathComponent(model.filename)
  }

  private func downloadFile(repoID: String, filename: String, to destination: URL) async throws {
    let encodedFile = filename
      .split(separator: "/")
      .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
      .joined(separator: "/")
    guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encodedFile)?download=true") else {
      throw LocalPostProcessingModelError.downloadFailed("Invalid Hugging Face URL for \(filename).")
    }
    let (downloadedURL, response) = try await URLSession.shared.download(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw LocalPostProcessingModelError.downloadFailed("Hugging Face returned HTTP \(http.statusCode) for \(filename).")
    }
    try fileManager.moveItem(at: downloadedURL, to: destination)
  }

  private func loadImportedModels() {
    guard fileManager.fileExists(atPath: importedModelsURL.path) else { return }
    do {
      let data = try Data(contentsOf: importedModelsURL)
      importedModels = try JSONDecoder().decode([LocalPostProcessingModel].self, from: data)
    } catch {
      logger.error("Failed to load local post-processing model sources: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func saveImportedModels() throws {
    let data = try JSONEncoder().encode(importedModels)
    try data.write(to: importedModelsURL, options: .atomic)
  }

  private func writeSidecarIfNeeded() throws {
    try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    let data = Data(Self.sidecarScript.utf8)
    if let existing = try? Data(contentsOf: sidecarURL), existing == data { return }
    try data.write(to: sidecarURL, options: .atomic)
  }

  nonisolated static func isDownloadedLocalModelID(_ id: String) -> Bool {
    id.lowercased().hasPrefix("local/post-processing/")
      && id.lowercased() != builtInRulesModelID
  }

  nonisolated static func huggingFaceModelID(repoID: String, filename: String) -> String {
    "local/post-processing/huggingface/\(LocalModelManager.slug(repoID))/\(LocalModelManager.slug(filename))"
  }

  nonisolated static func approximateSizeMB(from filename: String) -> Int? {
    let lower = filename.lowercased()
    let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(gb|mb)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
      let valueRange = Range(match.range(at: 1), in: lower),
      let unitRange = Range(match.range(at: 2), in: lower),
      let value = Double(lower[valueRange])
    else {
      return nil
    }
    let multiplier = lower[unitRange] == "gb" ? 1024.0 : 1.0
    return Int((value * multiplier).rounded())
  }

  nonisolated static func localUserPrompt(systemPrompt: String, rawText: String) -> String {
    """
    Follow these transcript cleanup instructions exactly:

    <instructions>
    \(systemPrompt)
    </instructions>

    Clean the following raw transcript. Return only the cleaned transcript text.

    <raw_transcript>
    \(rawText)
    </raw_transcript>
    """
  }

  private nonisolated static func displayName(repoID: String, filename: String) -> String {
    let base = filename
      .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    return "\(base) from \(repoID)"
  }

  private nonisolated static func runProcess(
    executableURL: URL,
    arguments: [String],
    standardInput: Data? = nil,
    environment: [String: String] = [:]
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if !environment.isEmpty {
          process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let standardInput {
          let inputPipe = Pipe()
          process.standardInput = inputPipe
          do {
            try process.run()
            inputPipe.fileHandleForWriting.write(standardInput)
            try inputPipe.fileHandleForWriting.close()
          } catch {
            continuation.resume(throwing: error)
            return
          }

        } else {
          do {
            try process.run()
          } catch {
            continuation.resume(throwing: error)
            return
          }
        }
        process.waitUntilExit()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
          continuation.resume(
            throwing: LocalPostProcessingModelError.runtimeUnavailable(
              errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
          )
          return
        }
        continuation.resume(returning: output)
      }
    }
  }

  private nonisolated static func readableRuntimeInstallError(from error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.contains("No matching distribution found") || message.contains("Could not find a version") {
      return "No compatible llama.cpp Python package was available for this Python version. Try installing Python 3.11 or 3.12, then install the runtime again."
    }
    if message.contains("cmake") || message.contains("CMake") {
      return "Building the llama.cpp runtime failed while preparing CMake. Install Xcode Command Line Tools, then try again."
    }
    if message.isEmpty {
      return "The llama.cpp runtime install failed. Check your Python installation and try again."
    }
    return String(message.prefix(500))
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
    system_prompt = request.get("systemPrompt") or ""
    raw_text = request.get("rawText") or ""
    user_prompt = request.get("userPrompt") or (
        "Follow these transcript cleanup instructions exactly:\n\n"
        "<instructions>\n"
        + system_prompt
        + "\n</instructions>\n\n"
        "Clean the following raw transcript. Return only the cleaned transcript text.\n\n"
        "<raw_transcript>\n"
        + raw_text
        + "\n</raw_transcript>"
    )
    temperature = float(request.get("temperature") or 0.2)

    llm = Llama(
        model_path=args.model,
        n_ctx=4096,
        n_threads=None,
        verbose=False,
    )
    response = llm.create_chat_completion(
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=temperature,
        max_tokens=1024,
    )
    text = response["choices"][0]["message"]["content"]
    print(json.dumps({"text": text}))


if __name__ == "__main__":
    main()
"""#
}

struct LocalPostProcessingModel: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let displayName: String
  let repoID: String
  let filename: String
  let approximateSizeMB: Int?
  let description: String

  init(
    id: String? = nil,
    displayName: String,
    repoID: String,
    filename: String,
    approximateSizeMB: Int?,
    description: String
  ) {
    self.id = id ?? LocalPostProcessingModelManager.huggingFaceModelID(repoID: repoID, filename: filename)
    self.displayName = displayName
    self.repoID = repoID
    self.filename = filename
    self.approximateSizeMB = approximateSizeMB
    self.description = description
  }

  var option: ModelCatalog.Option {
    ModelCatalog.Option(
      id: id,
      displayName: displayName,
      description: description,
      estimatedLatencyMs: 2_500,
      latencyTier: .medium,
      tags: [.privacy],
      pricing: nil,
      contextLength: 4_096
    )
  }

  var sizeLabel: String {
    guard let approximateSizeMB, approximateSizeMB > 0 else { return "Size unknown" }
    if approximateSizeMB >= 1024 {
      let gb = Double(approximateSizeMB) / 1024
      return "\(gb.formatted(.number.precision(.fractionLength(1)))) GB"
    }
    return "\(approximateSizeMB) MB"
  }
}

private struct LocalPostProcessingRequest: Codable {
  let systemPrompt: String
  let userPrompt: String
  let rawText: String
  let temperature: Double
}

private struct LocalPostProcessingResponse: Codable {
  let text: String
}
