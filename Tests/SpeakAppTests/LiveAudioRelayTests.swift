import XCTest

@testable import SpeakApp

final class LiveAudioRelayTests: XCTestCase {
  func testAttach_flushesQueuedBuffersInOrderThenForwardsLiveOnes() {
    let relay = LiveAudioRelay<Int>()
    relay.send(1)
    relay.send(2)
    XCTAssertEqual(relay.pendingCount, 2)

    var received: [Int] = []
    relay.attach { received.append($0) }
    relay.send(3)

    XCTAssertEqual(received, [1, 2, 3])
    XCTAssertEqual(relay.pendingCount, 0)
  }

  func testAttach_onlyFirstConsumerReceivesBuffers() {
    let relay = LiveAudioRelay<Int>()
    relay.send(1)
    var first: [Int] = []
    var second: [Int] = []
    relay.attach { first.append($0) }
    relay.attach { second.append($0) }
    relay.send(2)

    XCTAssertEqual(first, [1, 2])
    XCTAssertTrue(second.isEmpty)
  }

  func testClose_dropsQueuedBuffersAndIgnoresLaterOnes() {
    let relay = LiveAudioRelay<Int>()
    relay.send(1)
    relay.close()
    relay.send(2)

    var received: [Int] = []
    relay.attach { received.append($0) }
    relay.send(3)

    XCTAssertTrue(received.isEmpty)
    XCTAssertEqual(relay.pendingCount, 0)
  }

  func testSend_beyondPendingLimitKeepsEarliestBuffersAndCountsDrops() {
    let relay = LiveAudioRelay<Int>(pendingLimit: 2)
    for value in 1...4 { relay.send(value) }

    var received: [Int] = []
    relay.attach { received.append($0) }

    XCTAssertEqual(received, [1, 2])
    XCTAssertEqual(relay.droppedCount, 2)
  }
}
