import Foundation
import XCTest
@testable import SpeakApp

@MainActor
final class RepeatingTimerLifecycleTests: XCTestCase {
  @MainActor
  private final class CountingTarget: RepeatingTimerTarget {
    var fireCount = 0

    func repeatingTimerDidFire() {
      fireCount += 1
    }
  }

  func testTimer_deliversRepeatedCallbacksWhileOwnerLives() {
    let target = CountingTarget()
    let timer = WeakRepeatingTimerTarget.scheduledTimer(interval: 3600, target: target)
    defer { timer.invalidate() }

    timer.fire()
    timer.fire()

    XCTAssertEqual(target.fireCount, 2)
    XCTAssertTrue(timer.isValid)
  }

  func testTimer_doesNotRetainOwnerAndInvalidatesAfterOwnerRelease() throws {
    var target: CountingTarget? = CountingTarget()
    weak var weakTarget = target
    let timer = WeakRepeatingTimerTarget.scheduledTimer(interval: 3600, target: try XCTUnwrap(target))
    defer { timer.invalidate() }

    target = nil
    XCTAssertNil(weakTarget)
    timer.fire()
    XCTAssertFalse(timer.isValid)
  }

  func testLoadedHistoryManager_deallocatesWithRepeatingFlushScheduled() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileManager = TimerTestFileManager(supportURL: directory)
    var manager: HistoryManager? = HistoryManager(fileManager: fileManager, flushInterval: 3600)
    await manager?.waitUntilLoaded()
    XCTAssertEqual(manager?.loadState, .ready)
    weak var weakManager = manager

    manager = nil
    await Task.yield()

    XCTAssertNil(weakManager, "The periodic flush must not outlive the history owner")
  }
}

private final class TimerTestFileManager: FileManager, @unchecked Sendable {
  let supportURL: URL

  init(supportURL: URL) {
    self.supportURL = supportURL
    super.init()
  }

  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    directory == .applicationSupportDirectory ? [supportURL] : super.urls(for: directory, in: domainMask)
  }
}
