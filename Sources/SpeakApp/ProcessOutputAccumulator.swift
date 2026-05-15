import Foundation

final class ProcessOutputAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var stdoutData = Data()
  private var stderrData = Data()

  var stdout: String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: stdoutData, encoding: .utf8) ?? ""
  }

  var stderr: String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: stderrData, encoding: .utf8) ?? ""
  }

  func setStdout(_ data: Data) {
    lock.lock()
    stdoutData = data
    lock.unlock()
  }

  func setStderr(_ data: Data) {
    lock.lock()
    stderrData = data
    lock.unlock()
  }
}
