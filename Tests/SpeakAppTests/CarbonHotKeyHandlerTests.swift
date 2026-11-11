import Carbon
import os
import XCTest

@testable import SpeakApp

final class CarbonHotKeyHandlerTests: XCTestCase {
  private final class Received: @unchecked Sendable {
    let ids = OSAllocatedUnfairLock(initialState: [UInt32]())
  }

  func testDeliverPassesPressesOnUntilRemoved() {
    let received = Received()
    let handler = CarbonHotKeyHandler { id in received.ids.withLock { $0.append(id) } }

    XCTAssertTrue(handler.deliver(hotKeyID: 3))
    handler.remove()
    XCTAssertFalse(handler.deliver(hotKeyID: 4))
    handler.remove()

    XCTAssertEqual(received.ids.withLock { $0 }, [3])
    XCTAssertFalse(handler.isInstalled)
  }

  func testPressQueuedBeforeRetirementIsDropped() {
    let received = Received()
    var handler: CarbonHotKeyHandler? = CarbonHotKeyHandler { id in received.ids.withLock { $0.append(id) } }
    let unretained = Unmanaged.passUnretained(handler!)
    // Keep the object alive past `remove()` the way an in-flight Carbon
    // dispatch would hold its userData, then deliver.
    let retained = unretained.retain()
    handler = nil
    retained.takeUnretainedValue().remove()

    XCTAssertFalse(retained.takeUnretainedValue().deliver(hotKeyID: 1))
    retained.release()
    XCTAssertTrue(received.ids.withLock { $0 }.isEmpty)
  }
}
