import CryptoKit
import Foundation
import OSLog
import SpeakCore

#if !APP_STORE
// swiftlint:disable file_length
enum SherpaOnnxRuntimeError: LocalizedError {
  case pythonUnavailable
  case runtimeUnavailable(String)
  case unsupportedModel(String)
  case downloadFailed(String)
  case processFailed(String)
  case runtimeUpdateRequired(installed: String, required: String)

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
    case .runtimeUpdateRequired(let installed, let required):
      return "This model needs sherpa-onnx \(required) or later, but \(installed) is installed. "
        + "Choose Update Runtime in Local Streaming settings."
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
  let featureDim: Int
  /// sherpa-onnx model type: "transducer" runs the online recognizer;
  /// "nemo_transducer" runs the offline recognizer (e.g. NVIDIA Parakeet TDT).
  let modelType: String
  /// Whether the sidecar may pass a per-stream language prompt.
  var supportsLanguageHint = false
}

@MainActor
// swiftlint:disable:next type_body_length
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
      script: Self.sidecarScript,
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
        _ = try await Self.runProcess(executableURL: bootstrapPython, arguments: arguments)
      }
      _ = try await Self.runProcess(
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
    let finalDirectory = modelDirectory(for: source)
    let tempDirectory = finalDirectory.deletingLastPathComponent()
      .appendingPathComponent(finalDirectory.lastPathComponent + ".download", isDirectory: true)
    defer {
      if fileManager.fileExists(atPath: tempDirectory.path) {
        try? fileManager.removeItem(at: tempDirectory)
      }
    }
    do {
      let spec = try Self.specification(for: source)
      if fileManager.fileExists(atPath: tempDirectory.path) {
        try fileManager.removeItem(at: tempDirectory)
      }
      try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

      if let archiveURL = spec.archiveURL {
        try await downloadArchive(from: archiveURL, to: tempDirectory, expectedSHA256: spec.archiveSHA256)
      } else {
        for file in spec.files {
          let destination = tempDirectory.appendingPathComponent(file)
          try await downloadFile(repoID: source.repoID, filename: file, to: destination)
        }
      }

      try Task.checkCancellation()
      if fileManager.fileExists(atPath: finalDirectory.path) {
        try fileManager.removeItem(at: finalDirectory)
      }
      try fileManager.moveItem(at: tempDirectory, to: finalDirectory)
      modelStates[source.id] = .installed
    } catch is CancellationError {
      modelStates[source.id] = previousState
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
    if let required = try Self.specification(for: source).minimumRuntimeVersion,
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
      let output = try await Self.runProcess(
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

  private func downloadFile(repoID: String, filename: String, to destination: URL) async throws {
    try await HuggingFaceFileDownload.download(
      repoID: repoID, filename: filename, to: destination, fileManager: fileManager,
      failure: SherpaOnnxRuntimeError.downloadFailed
    )
  }

  private func downloadArchive(from url: URL, to destination: URL, expectedSHA256: String?) async throws {
    let (downloadedURL, response) = try await URLSession.shared.download(from: url)
    defer { try? fileManager.removeItem(at: downloadedURL) }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw SherpaOnnxRuntimeError.downloadFailed(
        "Download returned HTTP \(http.statusCode) for \(url.lastPathComponent)."
      )
    }
    if let expectedSHA256 {
      let actual = try await Task.detached(priority: .utility) {
        try Self.sha256Hex(of: downloadedURL)
      }.value
      guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
        throw SherpaOnnxRuntimeError.downloadFailed(
          "Checksum mismatch for \(url.lastPathComponent): expected \(expectedSHA256), got \(actual)."
        )
      }
    }
    do {
      _ = try await Self.runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-xf", downloadedURL.path, "-C", destination.path],
        timeout: LocalProcessRunner.extractionTimeout
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SherpaOnnxRuntimeError.downloadFailed(
        "Failed to extract model archive: \(error.localizedDescription)"
      )
    }
  }

  /// Streaming SHA256 so the ~0.5 GB model archives never need to sit in memory.
  private nonisolated static func sha256Hex(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated static func runProcess(
    executableURL: URL, arguments: [String], timeout: TimeInterval = LocalProcessRunner.setupTimeout
  ) async throws -> String {
    do {
      return try await LocalProcessRunner.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SherpaOnnxRuntimeError.runtimeUnavailable(error.localizedDescription)
    }
  }

  nonisolated static func specification(for source: LocalStreamingModelSource) throws -> ModelSpecification {
    if let nvidia = parakeetSpecification(for: source) ?? multilingualNemotronSpecification(for: source) {
      return nvidia
    }
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
    if repo.contains("nemotron-speech-streaming-en-0.6b")
      || source.modelName.lowercased().contains("nemotron-speech-streaming-en-0.6b") {
      let root = source.modelName
      return ModelSpecification(
        tokens: "\(root)/tokens.txt",
        encoder: "\(root)/encoder.int8.onnx",
        decoder: "\(root)/decoder.int8.onnx",
        joiner: "\(root)/joiner.int8.onnx",
        featureDim: 128,
        archiveURL: source.archiveURL
      )
    }
    if repo.contains("en-2023-06-21") {
      return ModelSpecification(
        tokens: "tokens.txt",
        encoder: "encoder-epoch-99-avg-1.int8.onnx",
        decoder: "decoder-epoch-99-avg-1.onnx",
        joiner: "joiner-epoch-99-avg-1.int8.onnx"
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

  /// NVIDIA Nemotron 3.5: multilingual cache-aware transducer. Needs the pinned
  /// runtime that added it and honours an explicit language hint.
  private nonisolated static func multilingualNemotronSpecification(
    for source: LocalStreamingModelSource
  ) -> ModelSpecification? {
    guard NemotronLocalModels.isMultilingual("\(source.repoID) \(source.modelName)") else { return nil }
    let root = source.modelName
    let variant = NemotronLocalModels.variant(named: root)
    return ModelSpecification(
      tokens: "\(root)/tokens.txt",
      encoder: "\(root)/encoder.int8.onnx",
      decoder: "\(root)/decoder.int8.onnx",
      joiner: "\(root)/joiner.int8.onnx",
      featureDim: 128,
      archiveURL: source.archiveURL ?? variant?.archiveURL,
      archiveSHA256: variant?.archiveSHA256,
      minimumRuntimeVersion: NemotronLocalModels.minimumRuntimeVersion,
      supportsLanguageHint: true
    )
  }

  /// NVIDIA Parakeet v3: offline NeMo TDT transducer. Decoded by the offline
  /// recognizer (model_type "nemo_transducer", greedy search) with the 128-dim
  /// mel features the NeMo export was trained on.
  private nonisolated static func parakeetSpecification(
    for source: LocalStreamingModelSource
  ) -> ModelSpecification? {
    let searchText = "\(source.repoID) \(source.modelName)".lowercased()
    guard searchText.contains("nemo-parakeet-tdt-0.6b-v3") else { return nil }
    let root = source.modelName
    return ModelSpecification(
      tokens: "\(root)/tokens.txt",
      encoder: "\(root)/encoder.int8.onnx",
      decoder: "\(root)/decoder.int8.onnx",
      joiner: "\(root)/joiner.int8.onnx",
      featureDim: 128,
      archiveURL: source.archiveURL ?? ParakeetLocalModels.tdtV3Int8ArchiveURL,
      modelType: "nemo_transducer",
      archiveSHA256: ParakeetLocalModels.tdtV3Int8ArchiveSHA256
    )
  }

  struct ModelSpecification {
    let tokens: String
    let encoder: String
    let decoder: String
    let joiner: String
    var featureDim: Int = 80
    var archiveURL: URL?
    /// "transducer" (online recognizer) unless the model is an offline NeMo
    /// transducer such as Parakeet TDT ("nemo_transducer").
    var modelType: String = "transducer"
    /// Pinned archive checksum, verified after download when present.
    var archiveSHA256: String?
    /// Oldest sherpa-onnx release known to decode this export.
    var minimumRuntimeVersion: String?
    /// Language-ID prompted models accept a per-stream language option.
    var supportsLanguageHint = false

    var files: [String] { [tokens, encoder, decoder, joiner] }
  }

  nonisolated static let sidecarScript = """
#!/usr/bin/env python3
import argparse
import array
import json
import sys

import sherpa_onnx


def emit(kind, text):
    print(json.dumps({"type": kind, "text": text}), flush=True)


def read_samples():
    chunk = sys.stdin.buffer.read(6400)
    if not chunk:
        return None
    usable = len(chunk) - (len(chunk) % 4)
    samples = array.array("f")
    if usable > 0:
        samples.frombytes(chunk[:usable])
    return samples


def run_online(args):
    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=args.tokens,
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        num_threads=2,
        sample_rate=16000,
        feature_dim=args.feature_dim,
        decoding_method="greedy_search",
        provider="cpu",
    )
    stream = recognizer.create_stream()
    if args.language:
        # Language-ID prompted exports (Nemotron 3.5) only; unset auto-detects.
        stream.set_option("language", args.language)
    last_text = ""

    while True:
        samples = read_samples()
        if samples is None:
            break
        if not samples:
            continue
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


def run_offline(args):
    # Offline transducers (e.g. NVIDIA Parakeet TDT) decode a whole utterance
    # at a time. Ingestion and inference are decoupled (issue #679): a reader
    # thread always drains stdin, so the pipe can never fill and block the
    # app's real-time audio queue behind model inference. Partials decode a
    # bounded tail window at an adaptive cadence (never more than ~half the
    # wall clock), so partial latency and per-decode cost stay constant for
    # long sessions instead of growing quadratically. The session final still
    # decodes every retained sample.
    import collections
    import threading
    import time

    recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        tokens=args.tokens,
        num_threads=2,
        sample_rate=16000,
        feature_dim=args.feature_dim,
        decoding_method="greedy_search",
        model_type=args.model_type,
        provider="cpu",
    )

    # Bounded retention: one hour of 16 kHz mono float32 (~230 MB). Beyond it
    # the oldest audio is dropped and the cap is reported once, so memory is
    # bounded and truncation is explicit rather than silent.
    max_buffer_samples = 16000 * 60 * 60
    # Partials decode at most the trailing minute, keeping each partial decode
    # constant-cost regardless of session length.
    partial_window_samples = 16000 * 60

    lock = threading.Lock()
    # Retained audio is a deque of PCM chunks rather than one flat array:
    # evicting old audio drops whole leading chunks (plus a prefix of one
    # small chunk), so a post-cap read costs the same as any other read
    # instead of shifting the whole hour of samples while the reader holds
    # the lock and stdin stops draining.
    buffered = collections.deque()
    retained = 0  # samples currently held in `buffered`
    received = 0  # samples accepted from stdin since start; never decreases
    eof = threading.Event()
    capped = threading.Event()

    def reader():
        nonlocal retained, received
        while True:
            samples = read_samples()
            if samples is None:
                break
            if not samples:
                continue
            with lock:
                buffered.append(samples)
                retained += len(samples)
                received += len(samples)
                while retained > max_buffer_samples:
                    excess = retained - max_buffer_samples
                    oldest = buffered[0]
                    if len(oldest) <= excess:
                        buffered.popleft()
                        retained -= len(oldest)
                    else:
                        del oldest[:excess]
                        retained -= excess
                    capped.set()
        eof.set()

    def snapshot(limit):
        # Concatenates the trailing `limit` retained samples (every retained
        # sample when `limit` is None). Called with the lock held.
        window = array.array("f")
        if limit is None or retained <= limit:
            for chunk in buffered:
                window.extend(chunk)
            return window
        remaining = limit
        tail = []
        for chunk in reversed(buffered):
            if len(chunk) >= remaining:
                tail.append(chunk[len(chunk) - remaining:])
                break
            tail.append(chunk)
            remaining -= len(chunk)
        for chunk in reversed(tail):
            window.extend(chunk)
        return window

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    def decode(window):
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, window)
        recognizer.decode_stream(stream)
        return stream.result.text

    last_text = ""
    # `received` at the last partial decode. Progress is measured against
    # samples accepted, not samples retained, so partials continue after the
    # retention cap holds the buffer at a constant length.
    decoded_upto = 0
    last_decode_seconds = 0.0
    did_report_cap = False

    def report_cap_once():
        nonlocal did_report_cap
        if capped.is_set() and not did_report_cap:
            did_report_cap = True
            emit("buffer_capped", "retention window exceeded; oldest audio dropped")

    while not eof.is_set():
        time.sleep(0.1)
        report_cap_once()
        with lock:
            available = received
        # Adaptive cadence: at least two seconds of new audio, and at least
        # twice the previous decode's duration, so decoding can never occupy
        # more than about half of real time and ingestion always stays ahead.
        required = int(16000 * max(2.0, last_decode_seconds * 2.0))
        if available - decoded_upto < required:
            continue
        with lock:
            window = snapshot(partial_window_samples)
        started = time.monotonic()
        text = decode(window)
        last_decode_seconds = time.monotonic() - started
        decoded_upto = available
        if text and text != last_text:
            last_text = text
            emit("partial", text)

    thread.join()
    # The reader can reach the cap between the last poll and EOF; the
    # truncation is still reported before the final transcript.
    report_cap_once()
    with lock:
        final_window = snapshot(None)
    emit("finalizing", "%.1f" % (len(final_window) / 16000.0))
    final_text = (decode(final_window) if final_window else "") or last_text
    emit("session_final", final_text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokens", required=True)
    parser.add_argument("--encoder", required=True)
    parser.add_argument("--decoder", required=True)
    parser.add_argument("--joiner", required=True)
    parser.add_argument("--feature-dim", type=int, default=80)
    parser.add_argument("--model-type", default="transducer")
    parser.add_argument("--language", default=None)
    args = parser.parse_args()

    if args.model_type == "transducer":
        run_online(args)
    else:
        run_offline(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"type": "error", "message": str(exc)}), flush=True)
        sys.exit(1)
"""
}

#endif
