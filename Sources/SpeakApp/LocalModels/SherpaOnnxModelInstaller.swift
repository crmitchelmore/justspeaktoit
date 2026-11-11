import CryptoKit
import Foundation
import SpeakCore

#if !APP_STORE
/// Runs sherpa-onnx setup processes, reporting failures as an unavailable
/// runtime while letting cancellation through unchanged.
enum SherpaOnnxProcess {
  static func run(
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
}

/// Downloads one model's files into a scratch directory and swaps it into
/// place only once every file has arrived, so a cancelled or failed install
/// never leaves a partial bundle behind. Main-actor bound like its owner,
/// `SherpaOnnxRuntimeManager`; only hashing leaves the main actor.
@MainActor
struct SherpaOnnxModelInstaller {
  let fileManager: FileManager

  func install(_ source: LocalStreamingModelSource, into finalDirectory: URL) async throws {
    let tempDirectory = finalDirectory.deletingLastPathComponent()
      .appendingPathComponent(finalDirectory.lastPathComponent + ".download", isDirectory: true)
    defer {
      if fileManager.fileExists(atPath: tempDirectory.path) {
        try? fileManager.removeItem(at: tempDirectory)
      }
    }
    let spec = try SherpaOnnxModelSpecification.resolve(for: source)
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
      _ = try await SherpaOnnxProcess.run(
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
}

#endif
