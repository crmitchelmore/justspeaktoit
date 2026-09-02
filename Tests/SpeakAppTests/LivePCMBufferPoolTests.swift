import AVFoundation
import XCTest

@testable import SpeakApp

final class LivePCMBufferPoolTests: XCTestCase {

  private func makeFormat(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
      preconditionFailure("Failed to build test audio format")
    }
    return format
  }

  func testRecycledBufferIsHandedBackOnNextCheckout() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()

    let first = pool.buffer(format: format, frameCapacity: 512)
    XCTAssertNotNil(first)
    pool.recycle(first!)

    let second = pool.buffer(format: format, frameCapacity: 512)
    XCTAssertTrue(second === first, "A recycled buffer of the same format and capacity should be reused")
  }

  func testCheckoutWithoutRecycleAllocatesFreshBuffers() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()

    let first = pool.buffer(format: format, frameCapacity: 512)
    let second = pool.buffer(format: format, frameCapacity: 512)
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertFalse(first === second, "A buffer still checked out must never be handed to a second caller")
  }

  func testRecycleResetsFrameLength() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()

    guard let buffer = pool.buffer(format: format, frameCapacity: 512) else {
      return XCTFail("Pool failed to vend a buffer")
    }
    buffer.frameLength = 256
    pool.recycle(buffer)

    let reused = pool.buffer(format: format, frameCapacity: 512)
    XCTAssertTrue(reused === buffer)
    XCTAssertEqual(reused?.frameLength, 0, "A pooled buffer must come back empty so the copy starts clean")
  }

  func testLargerCapacityRequestSkipsUndersizedPooledBuffer() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()

    guard let small = pool.buffer(format: format, frameCapacity: 256) else {
      return XCTFail("Pool failed to vend a buffer")
    }
    pool.recycle(small)

    let large = pool.buffer(format: format, frameCapacity: 1024)
    XCTAssertNotNil(large)
    XCTAssertFalse(large === small, "An undersized pooled buffer must not satisfy a larger request")
    XCTAssertGreaterThanOrEqual(large!.frameCapacity, 1024)

    // The undersized buffer is still pooled and still serves small requests.
    let smallAgain = pool.buffer(format: format, frameCapacity: 256)
    XCTAssertTrue(smallAgain === small)
  }

  func testOversizedPooledBufferSatisfiesSmallerRequest() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()

    guard let large = pool.buffer(format: format, frameCapacity: 1024) else {
      return XCTFail("Pool failed to vend a buffer")
    }
    pool.recycle(large)

    let small = pool.buffer(format: format, frameCapacity: 256)
    XCTAssertTrue(small === large, "A pooled buffer with spare capacity should still be reused")
  }

  func testFormatMismatchAllocatesInsteadOfReusing() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let mono = makeFormat(sampleRate: 48_000, channels: 1)
    let stereo = makeFormat(sampleRate: 48_000, channels: 2)

    guard let monoBuffer = pool.buffer(format: mono, frameCapacity: 512) else {
      return XCTFail("Pool failed to vend a buffer")
    }
    pool.recycle(monoBuffer)

    guard let stereoBuffer = pool.buffer(format: stereo, frameCapacity: 512) else {
      return XCTFail("Pool failed to vend a buffer")
    }
    XCTAssertFalse(stereoBuffer === monoBuffer, "Buffers must only be reused for an exactly matching format")
    XCTAssertEqual(stereoBuffer.format.channelCount, 2)

    // Recycling the stereo buffer must not shadow the pooled mono buffer.
    pool.recycle(stereoBuffer)
    let monoAgain = pool.buffer(format: mono, frameCapacity: 512)
    XCTAssertTrue(monoAgain === monoBuffer)
  }

  func testRecycleIsCappedAtMaximumBuffers() {
    let pool = LivePCMBufferPool(maximumBuffers: 2)
    let format = makeFormat()

    let buffers = (0..<3).compactMap { _ in pool.buffer(format: format, frameCapacity: 512) }
    XCTAssertEqual(buffers.count, 3)
    buffers.forEach(pool.recycle)

    // Only two of the three were retained, so the third checkout allocates.
    let firstOut = pool.buffer(format: format, frameCapacity: 512)
    let secondOut = pool.buffer(format: format, frameCapacity: 512)
    let thirdOut = pool.buffer(format: format, frameCapacity: 512)
    XCTAssertTrue(buffers.contains { $0 === firstOut })
    XCTAssertTrue(buffers.contains { $0 === secondOut })
    XCTAssertFalse(buffers.contains { $0 === thirdOut }, "The pool must not grow past maximumBuffers")
  }

  func testRemoveAllDropsPooledBuffers() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()

    guard let buffer = pool.buffer(format: format, frameCapacity: 512) else {
      return XCTFail("Pool failed to vend a buffer")
    }
    pool.recycle(buffer)
    pool.removeAll()

    let afterDrain = pool.buffer(format: format, frameCapacity: 512)
    XCTAssertNotNil(afterDrain)
    XCTAssertFalse(afterDrain === buffer, "removeAll must drop pooled buffers so a stopped session releases memory")
  }

  func testConcurrentCheckoutAndRecycleNeverVendsTheSameBufferTwice() {
    let pool = LivePCMBufferPool(maximumBuffers: 4)
    let format = makeFormat()
    let iterations = 200

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      guard let buffer = pool.buffer(format: format, frameCapacity: 512) else {
        return XCTFail("Pool failed to vend a buffer")
      }
      XCTAssertEqual(buffer.frameLength, 0)
      buffer.frameLength = 128
      pool.recycle(buffer)
    }

    // Surviving the race is the assertion; a double-vend would have tripped the
    // frameLength check above on some iteration.
    XCTAssertNotNil(pool.buffer(format: format, frameCapacity: 512))
  }
}
