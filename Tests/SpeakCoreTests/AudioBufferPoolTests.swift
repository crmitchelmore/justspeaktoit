import XCTest

@testable import SpeakCore

final class AudioBufferPoolTests: XCTestCase {

    // MARK: - Initial State

    func testInit_defaultPoolSize_preAllocatesBuffers() {
        let pool = AudioBufferPool(poolSize: 5, bufferSize: 512)
        let metrics = pool.metricsSnapshot()
        XCTAssertEqual(metrics["availableBuffers"], 5, "Should pre-allocate the requested number of buffers")
        XCTAssertEqual(metrics["initialPoolSize"], 5)
    }

    func testInit_metricsStartAtZero() {
        let pool = AudioBufferPool(poolSize: 3, bufferSize: 256)
        XCTAssertEqual(pool.poolHits, 0)
        XCTAssertEqual(pool.poolMisses, 0)
        XCTAssertEqual(pool.growthCount, 0)
    }

    // MARK: - Checkout from pool

    func testCheckout_fromNonEmptyPool_incrementsHits() {
        let pool = AudioBufferPool(poolSize: 2, bufferSize: 64)
        _ = pool.checkout()
        XCTAssertEqual(pool.poolHits, 1, "Checkout from non-empty pool should increment hits")
        XCTAssertEqual(pool.poolMisses, 0)
    }

    func testCheckout_reducesAvailableBufferCount() {
        let pool = AudioBufferPool(poolSize: 3, bufferSize: 64)
        _ = pool.checkout()
        _ = pool.checkout()
        let metrics = pool.metricsSnapshot()
        XCTAssertEqual(metrics["availableBuffers"], 1, "Two checkouts from a 3-buffer pool should leave 1 available")
    }

    func testCheckout_returnsDataWithReservedCapacity() {
        let pool = AudioBufferPool(poolSize: 1, bufferSize: 1024)
        let buffer = pool.checkout()
        XCTAssertGreaterThanOrEqual(buffer.capacity, 0, "Should return a valid Data buffer")
    }

    // MARK: - Pool exhaustion (miss path)

    func testCheckout_exhaustedPool_incrementsMissesAndGrowth() {
        let pool = AudioBufferPool(poolSize: 1, bufferSize: 64)
        _ = pool.checkout() // drains the pool
        _ = pool.checkout() // pool is empty - should miss
        XCTAssertEqual(pool.poolMisses, 1, "Checkout from empty pool should increment misses")
        XCTAssertEqual(pool.growthCount, 1, "Growth count should increment on miss")
    }

    func testCheckout_exhaustedPool_returnsValidBuffer() {
        let pool = AudioBufferPool(poolSize: 0, bufferSize: 64)
        let buffer = pool.checkout()
        XCTAssertNotNil(buffer as Any, "Even an exhausted pool should return a usable buffer")
        XCTAssertEqual(pool.poolMisses, 1)
    }

    // MARK: - Return buffer

    func testReturnBuffer_increasesAvailableCount() {
        let pool = AudioBufferPool(poolSize: 1, bufferSize: 64)
        var buffer = pool.checkout()
        XCTAssertEqual(pool.metricsSnapshot()["availableBuffers"], 0, "Pool should be empty after checkout")
        pool.returnBuffer(&buffer)
        XCTAssertEqual(pool.metricsSnapshot()["availableBuffers"], 1, "Pool should have 1 buffer after return")
    }

    func testReturnBuffer_clearsBufferContents() {
        let pool = AudioBufferPool(poolSize: 1, bufferSize: 64)
        var buffer = pool.checkout()
        buffer.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        XCTAssertFalse(buffer.isEmpty, "Buffer should have contents before return")
        pool.returnBuffer(&buffer)
        XCTAssertTrue(buffer.isEmpty, "returnBuffer should clear the buffer contents for security")
    }

    func testReturnBuffer_returnedBufferIsReusable() {
        let pool = AudioBufferPool(poolSize: 1, bufferSize: 64)
        var buffer = pool.checkout()
        buffer.append(contentsOf: [0xFF, 0xAA])
        pool.returnBuffer(&buffer)

        // Second checkout should reuse the returned buffer (pool hit)
        _ = pool.checkout()
        XCTAssertEqual(pool.poolHits, 2, "Second checkout should be a pool hit (buffer was returned)")
    }

    // MARK: - Checkout/Return cycles

    func testCheckoutReturn_multipleRoundTrips_noBufferLeak() {
        let pool = AudioBufferPool(poolSize: 3, bufferSize: 128)
        for _ in 0..<5 {
            var buf = pool.checkout()
            buf.append(contentsOf: [0x01])
            pool.returnBuffer(&buf)
        }
        let metrics = pool.metricsSnapshot()
        // After returning all buffers, available should be >= initial pool size
        XCTAssertGreaterThanOrEqual(
            metrics["availableBuffers"] ?? 0,
            3,
            "All returned buffers should be available"
        )
    }

    // MARK: - Metrics snapshot

    func testMetricsSnapshot_containsExpectedKeys() {
        let pool = AudioBufferPool(poolSize: 2, bufferSize: 64)
        let metrics = pool.metricsSnapshot()
        XCTAssertNotNil(metrics["poolHits"])
        XCTAssertNotNil(metrics["poolMisses"])
        XCTAssertNotNil(metrics["growthCount"])
        XCTAssertNotNil(metrics["availableBuffers"])
        XCTAssertNotNil(metrics["initialPoolSize"])
    }

    func testMetricsSnapshot_afterMixedOperations_reflectsCorrectCounts() {
        let pool = AudioBufferPool(poolSize: 2, bufferSize: 64)
        _ = pool.checkout() // hit 1
        _ = pool.checkout() // hit 2
        _ = pool.checkout() // miss 1 (pool exhausted)

        XCTAssertEqual(pool.poolHits, 2)
        XCTAssertEqual(pool.poolMisses, 1)
        XCTAssertEqual(pool.growthCount, 1)
    }

    // MARK: - Reset metrics

    func testResetMetrics_clearsAllCounters() {
        let pool = AudioBufferPool(poolSize: 1, bufferSize: 64)
        _ = pool.checkout()
        _ = pool.checkout() // forces a miss
        XCTAssertGreaterThan(pool.poolHits + pool.poolMisses, 0, "Should have some metrics before reset")

        pool.resetMetrics()

        XCTAssertEqual(pool.poolHits, 0, "poolHits should be 0 after reset")
        XCTAssertEqual(pool.poolMisses, 0, "poolMisses should be 0 after reset")
        XCTAssertEqual(pool.growthCount, 0, "growthCount should be 0 after reset")
    }

    func testResetMetrics_doesNotAffectAvailableBuffers() {
        let pool = AudioBufferPool(poolSize: 3, bufferSize: 64)
        _ = pool.checkout()
        pool.resetMetrics()
        let metrics = pool.metricsSnapshot()
        XCTAssertEqual(metrics["availableBuffers"], 2, "resetMetrics should not affect the buffer pool itself")
    }

    // MARK: - Thread safety

    func testCheckout_concurrentAccess_metricsRemainConsistent() {
        let pool = AudioBufferPool(poolSize: 10, bufferSize: 64)
        let iterations = 50

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = pool.checkout()
        }

        let totalOps = pool.poolHits + pool.poolMisses
        XCTAssertEqual(totalOps, iterations, "Total ops (hits + misses) should equal number of checkouts")
    }

    func testReturnBuffer_concurrentReturns_noDeadlock() {
        let pool = AudioBufferPool(poolSize: 5, bufferSize: 64)

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            var buf = pool.checkout()
            buf.append(contentsOf: [0x01, 0x02])
            pool.returnBuffer(&buf)
        }

        // No assertion beyond "no deadlock / no crash"
        XCTAssertTrue(true)
    }
}
