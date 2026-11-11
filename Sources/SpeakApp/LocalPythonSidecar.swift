#if !APP_STORE
import Foundation

/// The Python virtual environment and sidecar script behind one downloaded
/// local-model runtime (llama.cpp post-processing, sherpa-onnx streaming).
/// Each runtime owns its own instance, so environments never share a venv.
@MainActor
final class LocalPythonSidecar {
  /// System interpreters that may seed the virtual environment, in order.
  nonisolated static let bootstrapCandidates = [
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3"
  ]

  let virtualEnvironmentURL: URL
  let scriptURL: URL
  private let script: String
  private let fileManager: FileManager
  private let pythonUnavailable: () -> Error
  private var pythonExecutableCache: URL?

  init(
    virtualEnvironmentURL: URL,
    scriptURL: URL,
    script: String,
    fileManager: FileManager = .default,
    pythonUnavailable: @escaping () -> Error
  ) {
    self.virtualEnvironmentURL = virtualEnvironmentURL
    self.scriptURL = scriptURL
    self.script = script
    self.fileManager = fileManager
    self.pythonUnavailable = pythonUnavailable
  }

  var venvPythonURL: URL {
    virtualEnvironmentURL
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("python3")
  }

  var hasVirtualEnvironment: Bool {
    fileManager.fileExists(atPath: venvPythonURL.path)
  }

  /// The venv interpreter once it exists, otherwise a system interpreter.
  func pythonExecutable() throws -> URL {
    if fileManager.isExecutableFile(atPath: venvPythonURL.path) {
      pythonExecutableCache = venvPythonURL
      return venvPythonURL
    }
    if let pythonExecutableCache { return pythonExecutableCache }
    return try bootstrapPythonExecutable()
  }

  func bootstrapPythonExecutable() throws -> URL {
    for candidate in Self.bootstrapCandidates where fileManager.isExecutableFile(atPath: candidate) {
      let url = URL(fileURLWithPath: candidate)
      pythonExecutableCache = url
      return url
    }
    throw pythonUnavailable()
  }

  /// Creates the venv when missing (using `createVenv` with the bootstrap
  /// interpreter) and returns its interpreter, now preferred for every run.
  func prepareVirtualEnvironment(
    createVenv: (_ bootstrapPython: URL, _ arguments: [String]) async throws -> Void
  ) async throws -> URL {
    let bootstrapPython = try bootstrapPythonExecutable()
    if !hasVirtualEnvironment {
      try await createVenv(bootstrapPython, ["-m", "venv", virtualEnvironmentURL.path])
    }
    pythonExecutableCache = venvPythonURL
    return venvPythonURL
  }

  /// The sidecar script, rewritten only when its contents changed.
  func currentScriptURL() throws -> URL {
    try writeScriptIfNeeded()
    return scriptURL
  }

  func writeScriptIfNeeded() throws {
    try fileManager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(script.utf8)
    if let existing = try? Data(contentsOf: scriptURL), existing == data { return }
    try data.write(to: scriptURL, options: .atomic)
  }
}

/// Downloads one file from a Hugging Face model repository's main branch.
enum HuggingFaceFileDownload {
  static func url(repoID: String, filename: String) -> URL? {
    let encodedFile = filename
      .split(separator: "/")
      .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
      .joined(separator: "/")
    return URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encodedFile)?download=true")
  }

  /// Moves the downloaded file to `destination`, creating its directory.
  /// `failure` maps a message to the caller's own download error.
  static func download(
    repoID: String,
    filename: String,
    to destination: URL,
    fileManager: FileManager = .default,
    failure: (String) -> Error
  ) async throws {
    guard let url = url(repoID: repoID, filename: filename) else {
      throw failure("Invalid Hugging Face URL for \(filename).")
    }
    let (downloadedURL, response) = try await URLSession.shared.download(from: url)
    defer { try? fileManager.removeItem(at: downloadedURL) }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw failure("Hugging Face returned HTTP \(http.statusCode) for \(filename).")
    }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.moveItem(at: downloadedURL, to: destination)
  }
}
#endif
