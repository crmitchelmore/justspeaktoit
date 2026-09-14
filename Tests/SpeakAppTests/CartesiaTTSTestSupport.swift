import Foundation
import SpeakTestSupport
import XCTest

/// Serial counter for multi-page stubs; the protocol stub runs its handler off
/// the test's own thread.
final class CartesiaTTSPageCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let current = value
    value += 1
    return current
  }
}

