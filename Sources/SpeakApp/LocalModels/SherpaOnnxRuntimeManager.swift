import Foundation
import OSLog
import SpeakCore

#if !APP_STORE
/// Owns the experimental sherpa-onnx runtime: its Python environment, install
/// state and the downloaded model bundles live streaming loads.
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

  /// The sherpa-onnx version `installRuntime()` installs. Older installed
  /// runtimes keep serving models whose specification allows them.
  nonisolated static let pinnedRuntimeVersion = "1.13.5"

  @Published private(set) var runtimeState: InstallState = .notInstalled
  /// Version reported by the installed runtime, when it reports one.
  @Published private(set) var installedRuntimeVersion: String?

  var runtimeUpdateAvailable: Bool {
    guard runtimeState.isInstalled else { return false }
    // A runtime too old to report its version is older than the pin.
    return !Self.isVersion(installedRuntimeVersion ?? "0", atLeast: Self.pinnedRuntimeVersion)
  }
  @Published private(set) var modelStates: [String: InstallState] = [:]

  private let fileManager: FileManager
  private let logger = SpeakLogger.logger(category: "SherpaOnnxRuntime")
  private let baseDirectory: URL
  private let sidecar: LocalPythonSidecar

  private init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    baseDirectory = base
        .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
      .appendingPathComponent("LocalModels", isDirectory: true)
      .appendingPathComponent("SherpaOnnx", isDirectory: true)
    sidecar = LocalPythonSidecar(
      virtualEnvironmentURL: baseDirectory.appendingPathComponent("venv", isDirectory: true),
      scriptURL: baseDirectory
        .appendingPathComponent("runtime", isDirectory: true)
        .appendingPathComponent("sherpa_stream.py"),
      script: SherpaOnnxSidecarScript.source,
      fileManager: fileManager,
      pythonUnavailable: { SherpaOnnxRuntimeError.pythonUnavailable }
    )
    do {
      try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
      try sidecar.writeScriptIfNeeded()
    } catch {
      runtimeState = .failed(error.localizedDescription)
    }
    refresh()
  }

  func refresh() {
    Task { await refreshRuntimeState() }
    for source in LocalModelManager.recommendedStreamingModelSources {
      if modelStates[source.id] == .installing {
        continue
      }
      modelStates[source.id] = modelBundleExists(for: source) ? .installed : .notInstalled
    }
    for source in LocalModelManager.shared.streamingModelSources {
      if modelStates[source.id] == .installing {
        continue
      }
      modelStates[source.id] = modelBundleExists(for: source) ? .installed : .notInstalled
    }
  }

  func installRuntime() async {
    guard runtimeState != .installing else { return }
    let previousState = runtimeState
    runtimeState = .installing
    do {
      let python = try await sidecar.prepareVirtualEnvironment { bootstrapPython, arguments in
        _ = try await SherpaOnnxProcess.run(executableURL: bootstrapPython, arguments: arguments)
      }
      _ = try await SherpaOnnxProcess.run(
        executableURL: python,
        arguments: ["-m", "pip", "install", "sherpa-onnx==\(Self.pinnedRuntimeVersion)"]
      )
      _ = try await ensureRuntimeAvailable()
      try Task.checkCancellation()
      runtimeState = .installed
    } catch is CancellationError {
      runtimeState = previousState
    } catch {
      // A failed upgrade can leave the previous runtime usable; keep offering it.
      if (try? await ensureRuntimeAvailable()) != nil, !Task.isCancelled {
        runtimeState = .installed
      } else {
        runtimeState = .failed(error.localizedDescription)
      }
    }
  }

  func installModel(_ source: LocalStreamingModelSource) async {
    guard modelStates[source.id] != .installing else { return }
    let previousState = modelStates[source.id] ?? .notInstalled
    modelStates[source.id] = .installing
    do {
      try await SherpaOnnxModelInstaller(fileManager: fileManager)
        .install(source, into: modelDirectory(for: source))
      modelStates[source.id] = .installed
    } catch is CancellationError {
      modelStates[source.id] = previousState
    } catch {
      modelStates[source.id] = .failed(error.localizedDescription)
    }
  }

  func bundle(for source: LocalStreamingModelSource) throws -> SherpaOnnxModelBundle {
    let spec = try SherpaOnnxModelSpecification.resolve(for: source)
    let directory = modelDirectory(for: source)
    let bundle = SherpaOnnxModelBundle(
      source: source,
      directory: directory,
      tokens: directory.appendingPathComponent(spec.tokens),
      encoder: directory.appendingPathComponent(spec.encoder),
      decoder: directory.appendingPathComponent(spec.decoder),
      joiner: directory.appendingPathComponent(spec.joiner),
      featureDim: spec.featureDim,
      modelType: spec.modelType,
      supportsLanguageHint: spec.supportsLanguageHint
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
    try sidecar.currentScriptURL()
  }

  func pythonExecutable() throws -> URL {
    try sidecar.pythonExecutable()
  }

  func ensureReady(sourceID: String) async throws -> SherpaOnnxModelBundle {
    let source = try source(for: sourceID)
    let version = try await ensureRuntimeAvailable()
    try Task.checkCancellation()
    if let required = try SherpaOnnxModelSpecification.resolve(for: source).minimumRuntimeVersion,
      !Self.isVersion(version ?? "0", atLeast: required) {
      throw SherpaOnnxRuntimeError.runtimeUpdateRequired(installed: version ?? "an older version", required: required)
    }
    return try bundle(for: source)
  }

  private func refreshRuntimeState() async {
    guard runtimeState != .installing else { return }
    do {
      _ = try await ensureRuntimeAvailable()
      try Task.checkCancellation()
      runtimeState = .installed
    } catch is CancellationError {
      return
    } catch {
      runtimeState = .notInstalled
    }
  }

  /// Confirms the module imports and returns the version it reports, if any.
  @discardableResult
  private func ensureRuntimeAvailable() async throws -> String? {
    let python = try pythonExecutable()
    do {
      let output = try await SherpaOnnxProcess.run(
        executableURL: python,
        arguments: ["-c", "import sherpa_onnx; print(getattr(sherpa_onnx, '__version__', 'ok'))"],
        timeout: LocalProcessRunner.probeTimeout
      )
      let reported = output.split(whereSeparator: \.isNewline).last.map(String.init)
      let version = reported.flatMap { $0.first?.isNumber == true ? $0 : nil }
      installedRuntimeVersion = version
      return version
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SherpaOnnxRuntimeError.runtimeUnavailable(error.localizedDescription)
    }
  }

  /// Numeric dotted-version comparison; non-numeric suffixes are ignored.
  nonisolated static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
    func parts(_ value: String) -> [Int] {
      value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let lhs = parts(version)
    let rhs = parts(minimum)
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left > right }
    }
    return true
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
}

#endif
