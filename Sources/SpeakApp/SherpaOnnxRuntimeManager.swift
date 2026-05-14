import Foundation
import OSLog

enum SherpaOnnxRuntimeError: LocalizedError {
  case pythonUnavailable
  case runtimeUnavailable(String)
  case unsupportedModel(String)
  case downloadFailed(String)
  case processFailed(String)

  var errorDescription: String? {
    switch self {
    case .pythonUnavailable:
      return "Python 3 was not found. Install Python 3 to enable experimental sherpa-onnx local streaming."
    case .runtimeUnavailable(let details):
      return "sherpa-onnx is not installed for Python 3. \(details)"
    case .unsupportedModel(let model):
      return "\(model) is not a supported sherpa-onnx streaming model in this prerelease."
    case .downloadFailed(let details):
      return "Could not download the sherpa-onnx model files. \(details)"
    case .processFailed(let details):
      return "sherpa-onnx failed to start. \(details)"
    }
  }
}

struct SherpaOnnxModelBundle: Equatable, Sendable {
  let source: LocalStreamingModelSource
  let directory: URL
  let tokens: URL
  let encoder: URL
  let decoder: URL
  let joiner: URL
}

@MainActor
final class SherpaOnnxRuntimeManager: ObservableObject {
  static let shared = SherpaOnnxRuntimeManager()

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

  @Published private(set) var runtimeState: InstallState = .notInstalled
  @Published private(set) var modelStates: [String: InstallState] = [:]

  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.github.speakapp", category: "SherpaOnnxRuntime")
  private let baseDirectory: URL
  private let sidecarURL: URL
  private let virtualEnvironmentURL: URL
  private var pythonExecutableCache: URL?

  private init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    baseDirectory = base
      .appendingPathComponent("SpeakApp", isDirectory: true)
      .appendingPathComponent("LocalModels", isDirectory: true)
      .appendingPathComponent("SherpaOnnx", isDirectory: true)
    virtualEnvironmentURL = baseDirectory.appendingPathComponent("venv", isDirectory: true)
    sidecarURL = baseDirectory
      .appendingPathComponent("runtime", isDirectory: true)
      .appendingPathComponent("sherpa_stream.py")
    do {
      try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
      try writeSidecarIfNeeded()
    } catch {
      runtimeState = .failed(error.localizedDescription)
    }
    refresh()
  }

  func refresh() {
    Task { await refreshRuntimeState() }
    for source in LocalModelManager.recommendedStreamingModelSources {
      modelStates[source.id] = modelBundleExists(for: source) ? .installed : .notInstalled
    }
    for source in LocalModelManager.shared.streamingModelSources {
      modelStates[source.id] = modelBundleExists(for: source) ? .installed : .notInstalled
    }
  }

  func installRuntime() async {
    runtimeState = .installing
    do {
      let bootstrapPython = try bootstrapPythonExecutable()
      if !fileManager.fileExists(atPath: venvPythonURL.path) {
        _ = try await Self.runProcess(
          executableURL: bootstrapPython,
          arguments: ["-m", "venv", virtualEnvironmentURL.path]
        )
      }

      let python = venvPythonURL
      pythonExecutableCache = python
      _ = try await Self.runProcess(
        executableURL: python,
        arguments: ["-m", "pip", "install", "sherpa-onnx==1.13.2"]
      )
      try await ensureRuntimeAvailable()
      runtimeState = .installed
    } catch {
      runtimeState = .failed(error.localizedDescription)
    }
  }

  func installModel(_ source: LocalStreamingModelSource) async {
    modelStates[source.id] = .installing
    do {
      let spec = try Self.specification(for: source)
      let finalDirectory = modelDirectory(for: source)
      let tempDirectory = finalDirectory.deletingLastPathComponent()
        .appendingPathComponent(finalDirectory.lastPathComponent + ".download", isDirectory: true)
      if fileManager.fileExists(atPath: tempDirectory.path) {
        try fileManager.removeItem(at: tempDirectory)
      }
      try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

      for file in spec.files {
        let destination = tempDirectory.appendingPathComponent(file)
        try await downloadFile(repoID: source.repoID, filename: file, to: destination)
      }

      if fileManager.fileExists(atPath: finalDirectory.path) {
        try fileManager.removeItem(at: finalDirectory)
      }
      try fileManager.moveItem(at: tempDirectory, to: finalDirectory)
      modelStates[source.id] = .installed
    } catch {
      modelStates[source.id] = .failed(error.localizedDescription)
    }
  }

  func bundle(for source: LocalStreamingModelSource) throws -> SherpaOnnxModelBundle {
    let spec = try Self.specification(for: source)
    let directory = modelDirectory(for: source)
    let bundle = SherpaOnnxModelBundle(
      source: source,
      directory: directory,
      tokens: directory.appendingPathComponent(spec.tokens),
      encoder: directory.appendingPathComponent(spec.encoder),
      decoder: directory.appendingPathComponent(spec.decoder),
      joiner: directory.appendingPathComponent(spec.joiner)
    )
    guard fileManager.fileExists(atPath: bundle.tokens.path),
      fileManager.fileExists(atPath: bundle.encoder.path),
      fileManager.fileExists(atPath: bundle.decoder.path),
      fileManager.fileExists(atPath: bundle.joiner.path)
    else {
      throw SherpaOnnxRuntimeError.unsupportedModel(source.displayName)
    }
    return bundle
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
      "/usr/bin/python3"
    ]
    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
      let url = URL(fileURLWithPath: candidate)
      pythonExecutableCache = url
      return url
    }
    throw SherpaOnnxRuntimeError.pythonUnavailable
  }

  func ensureReady(sourceID: String) async throws -> SherpaOnnxModelBundle {
    let source = try source(for: sourceID)
    try await ensureRuntimeAvailable()
    return try bundle(for: source)
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
    do {
      _ = try await Self.runProcess(
        executableURL: python,
        arguments: ["-c", "import sherpa_onnx; print(getattr(sherpa_onnx, '__version__', 'ok'))"]
      )
    } catch {
      throw SherpaOnnxRuntimeError.runtimeUnavailable(error.localizedDescription)
    }
  }

  private func source(for sourceID: String) throws -> LocalStreamingModelSource {
    if let source = LocalModelManager.shared.streamingModelSources.first(where: { $0.id == sourceID })
      ?? LocalModelManager.recommendedStreamingModelSources.first(where: { $0.id == sourceID }) {
      return source
    }
    throw SherpaOnnxRuntimeError.unsupportedModel(sourceID)
  }

  private func modelBundleExists(for source: LocalStreamingModelSource) -> Bool {
    (try? bundle(for: source)) != nil
  }

  private func modelDirectory(for source: LocalStreamingModelSource) -> URL {
    baseDirectory.appendingPathComponent(source.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
  }

  private func downloadFile(repoID: String, filename: String, to destination: URL) async throws {
    let encodedFile = filename
      .split(separator: "/")
      .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
      .joined(separator: "/")
    guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encodedFile)?download=true") else {
      throw SherpaOnnxRuntimeError.downloadFailed("Invalid Hugging Face URL for \(filename).")
    }
    let (downloadedURL, response) = try await URLSession.shared.download(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw SherpaOnnxRuntimeError.downloadFailed("Hugging Face returned HTTP \(http.statusCode) for \(filename).")
    }
    try fileManager.moveItem(at: downloadedURL, to: destination)
  }

  private nonisolated static func runProcess(executableURL: URL, arguments: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let group = DispatchGroup()
        let output = ProcessOutputAccumulator()
        let drain: (FileHandle, @escaping (Data) -> Void) -> Void = { handle, store in
          group.enter()
          DispatchQueue.global(qos: .utility).async {
            let data = handle.readDataToEndOfFile()
            store(data)
            group.leave()
          }
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
          drain(outputPipe.fileHandleForReading, output.setStdout)
          drain(errorPipe.fileHandleForReading, output.setStderr)
          try process.run()
          process.waitUntilExit()
          group.notify(queue: .global(qos: .utility)) {
            let outputText = output.stdout
            let errorText = output.stderr.isEmpty ? outputText : output.stderr
            guard process.terminationStatus == 0 else {
              continuation.resume(
                throwing: SherpaOnnxRuntimeError.runtimeUnavailable(
                  errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
              )
              return
            }
            continuation.resume(returning: outputText)
          }
        } catch {
          outputPipe.fileHandleForReading.closeFile()
          errorPipe.fileHandleForReading.closeFile()
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func writeSidecarIfNeeded() throws {
    try fileManager.createDirectory(at: sidecarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(Self.sidecarScript.utf8)
    if let existing = try? Data(contentsOf: sidecarURL), existing == data {
      return
    }
    try data.write(to: sidecarURL, options: .atomic)
  }

  private nonisolated static func specification(for source: LocalStreamingModelSource) throws -> ModelSpecification {
    let repo = source.repoID.lowercased()
    if repo.contains("en-20m-2023-02-17") {
      return ModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder-epoch-99-avg-1.int8.onnx",
        decoder: "decoder-epoch-99-avg-1.int8.onnx",
        joiner: "joiner-epoch-99-avg-1.int8.onnx"
      )
    }
    if repo.contains("en-kroko-2025-08-06") {
      return ModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder.onnx",
        decoder: "decoder.onnx",
        joiner: "joiner.onnx"
      )
    }
    if repo.contains("en-2023-06-26") {
      return ModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx",
        decoder: "decoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx",
        joiner: "joiner-epoch-99-avg-1-chunk-16-left-64.int8.onnx"
      )
    }
    throw SherpaOnnxRuntimeError.unsupportedModel(source.displayName)
  }

  private struct ModelSpecification {
    let tokens: String
    let encoder: String
    let decoder: String
    let joiner: String

    var files: [String] { [tokens, encoder, decoder, joiner] }
  }

  private nonisolated static let sidecarScript = """
#!/usr/bin/env python3
import argparse
import array
import json
import sys

import sherpa_onnx


def emit(kind, text):
    print(json.dumps({"type": kind, "text": text}), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokens", required=True)
    parser.add_argument("--encoder", required=True)
    parser.add_argument("--decoder", required=True)
    parser.add_argument("--joiner", required=True)
    args = parser.parse_args()

    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=args.tokens,
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        num_threads=2,
        sample_rate=16000,
        feature_dim=80,
        decoding_method="greedy_search",
        provider="cpu",
    )
    stream = recognizer.create_stream()
    last_text = ""

    while True:
        chunk = sys.stdin.buffer.read(6400)
        if not chunk:
            break
        usable = len(chunk) - (len(chunk) % 4)
        if usable <= 0:
            continue
        samples = array.array("f")
        samples.frombytes(chunk[:usable])
        stream.accept_waveform(16000, samples)
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        text = recognizer.get_result(stream)
        if text and text != last_text:
            last_text = text
            emit("partial", text)

    stream.input_finished()
    while recognizer.is_ready(stream):
        recognizer.decode_stream(stream)
    final_text = recognizer.get_result(stream) or last_text
    emit("session_final", final_text)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"type": "error", "message": str(exc)}), flush=True)
        sys.exit(1)
"""
}
