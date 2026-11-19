import Foundation

#if !APP_STORE
/// One JSON line the sherpa-onnx sidecar writes to stdout.
struct SherpaOnnxSidecarEvent: Decodable, Equatable {
  let type: String
  let text: String?
  let message: String?
}

/// Reassembles the sidecar's stdout into whole JSON lines. A pipe read can end
/// mid-line, so the trailing fragment is held until its newline arrives or the
/// stream is flushed at the end of the run. Lines that are not sidecar events
/// (stray prints, partial JSON) are dropped.
struct SherpaOnnxSidecarEventStream {
  private var buffer = ""

  /// Appends one pipe read and returns the events on every line it completed.
  mutating func append(_ data: Data) -> [SherpaOnnxSidecarEvent] {
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    buffer += output
    let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
    buffer = lines.last.map(String.init) ?? ""
    return lines.dropLast().compactMap { Self.decode(String($0)) }
  }

  /// Decodes whatever is left once the sidecar has exited, then empties the buffer.
  mutating func flush() -> SherpaOnnxSidecarEvent? {
    let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer = ""
    guard !remaining.isEmpty else { return nil }
    return Self.decode(remaining)
  }

  private static func decode(_ line: String) -> SherpaOnnxSidecarEvent? {
    guard let lineData = line.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SherpaOnnxSidecarEvent.self, from: lineData)
  }
}

/// Capped, lock-guarded store for one sidecar's stderr.
///
/// The pipe's readability handler runs on its own dispatch queue and appends
/// here directly, so draining costs no task allocation per read and the
/// retained bytes stay bounded regardless of how chatty the process is.
/// Bytes are decoded only when read back: `availableData` can split a
/// multibyte UTF-8 sequence across two reads, which would make a per-chunk
/// decode drop the chunk.
final class SherpaOnnxSidecarErrorSink: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let maxByteCount: Int

  init(maxByteCount: Int) {
    self.maxByteCount = maxByteCount
  }

  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    guard buffer.count > maxByteCount else { return }
    buffer.removeFirst(buffer.count - maxByteCount)
    // Trimming the head can land mid-character; drop the orphaned
    // continuation bytes so the log doesn't start with a replacement char.
    while let first = buffer.first, first & 0xC0 == 0x80 {
      buffer.removeFirst()
    }
  }

  func drainText() -> String {
    lock.lock()
    let captured = buffer
    buffer = Data()
    lock.unlock()
    // Deliberately lossy: a failable decode would throw away a whole log
    // fragment because the head was trimmed mid-character.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: captured, as: UTF8.self)
  }
}

/// Reads buffered bytes until EOF, bounded so a pipe that somehow still has a
/// writer attached can never spin the main actor indefinitely.
enum SherpaOnnxSidecarPipe {
  static func remainingData(on handle: FileHandle) -> [Data] {
    var chunks: [Data] = []
    for _ in 0..<8 {
      let chunk = handle.availableData
      guard !chunk.isEmpty else { break }
      chunks.append(chunk)
    }
    return chunks
  }
}
#endif
