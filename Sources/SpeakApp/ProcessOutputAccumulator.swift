import Foundation

/// Drains both child-process pipes without retaining unlimited compiler/model logs.
/// Each stream keeps at most 1 MiB; stderr keeps the tail where failure details land.
final class ProcessOutputAccumulator: @unchecked Sendable {
  private struct Capture {
    var data = Data()
    var truncated = false
    var readError: String?
  }

  private let lock = NSLock()
  private let byteLimit: Int
  private var stdoutCapture = Capture()
  private var stderrCapture = Capture()

  init(byteLimit: Int = 1024 * 1024) {
    precondition(byteLimit > 0)
    self.byteLimit = byteLimit
  }

  var stdout: String {
    lock.lock()
    defer { lock.unlock() }
    // A capped stream can end inside a UTF-8 scalar; preserve the readable bytes.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: stdoutCapture.data, as: UTF8.self)
  }

  var stderr: String {
    lock.lock()
    defer { lock.unlock() }
    let marker = stderrCapture.truncated ? "[Earlier process diagnostics omitted]\n" : ""
    // The retained tail can begin inside a UTF-8 scalar; never discard the diagnostics.
    // swiftlint:disable:next optional_data_string_conversion
    return marker + String(decoding: stderrCapture.data, as: UTF8.self)
  }

  /// A clipped stdout must never be treated as a complete model/probe response.
  var captureError: String? {
    lock.lock()
    defer { lock.unlock() }
    if let error = stdoutCapture.readError ?? stderrCapture.readError {
      return "Could not read local process output: \(error)"
    }
    return stdoutCapture.truncated ? "Local process output exceeded the \(byteLimit)-byte limit." : nil
  }

  func captureStdout(from handle: FileHandle) {
    let capture = read(from: handle, keepingTail: false)
    lock.lock()
    stdoutCapture = capture
    lock.unlock()
  }

  func captureStderr(from handle: FileHandle) {
    let capture = read(from: handle, keepingTail: true)
    lock.lock()
    stderrCapture = capture
    lock.unlock()
  }

  private func read(from handle: FileHandle, keepingTail: Bool) -> Capture {
    var capture = Capture()
    defer { try? handle.close() }
    do {
      // Continue consuming after the retention cap: stopping here fills the pipe
      // and deadlocks the child before its termination handler can run.
      while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        let available = byteLimit - capture.data.count
        if chunk.count > available { capture.truncated = true }
        if keepingTail {
          if chunk.count >= byteLimit {
            capture.data = Data(chunk.suffix(byteLimit))
          } else {
            let overflow = max(0, chunk.count - available)
            if overflow > 0 { capture.data.removeFirst(overflow) }
            capture.data.append(chunk)
          }
        } else {
          capture.data.append(contentsOf: chunk.prefix(available))
        }
      }
    } catch {
      capture.readError = error.localizedDescription
    }
    return capture
  }
}
