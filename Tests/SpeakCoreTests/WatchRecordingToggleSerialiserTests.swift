import XCTest
@testable import SpeakCore

@MainActor
final class WatchRecordingToggleSerialiserTests: XCTestCase {
    func testRun_serialisesOperationsAcrossSuspensionPoints() async {
        let serialiser = WatchRecordingToggleSerialiser()
        let probe = SerialiserProbe()

        let first = Task { @MainActor in
            await serialiser.run {
                await probe.enterFirstAndWait()
                await probe.leave()
            }
        }
        await probe.waitUntilFirstEntered()

        let second = Task { @MainActor in
            await serialiser.run {
                await probe.enterSecond()
                await probe.leave()
            }
        }
        await Task.yield()
        await probe.releaseFirst()

        await first.value
        await second.value
        let result = await probe.result()
        XCTAssertEqual(result.operationOrder, [1, 2])
        XCTAssertEqual(result.maximumConcurrentOperations, 1)
    }
}

private actor SerialiserProbe {
    private var activeOperations = 0
    private var maximumConcurrentOperations = 0
    private var operationOrder: [Int] = []
    private var firstEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func enterFirstAndWait() async {
        self.enter(operation: 1)
        self.firstEnteredWaiters.forEach { $0.resume() }
        self.firstEnteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.firstRelease = continuation
        }
    }

    func enterSecond() {
        self.enter(operation: 2)
    }

    func waitUntilFirstEntered() async {
        guard self.operationOrder.isEmpty else { return }
        await withCheckedContinuation { continuation in
            self.firstEnteredWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        self.firstRelease?.resume()
        self.firstRelease = nil
    }

    func leave() {
        self.activeOperations -= 1
    }

    func result() -> (operationOrder: [Int], maximumConcurrentOperations: Int) {
        (self.operationOrder, self.maximumConcurrentOperations)
    }

    private func enter(operation: Int) {
        self.activeOperations += 1
        self.maximumConcurrentOperations = max(self.maximumConcurrentOperations, self.activeOperations)
        self.operationOrder.append(operation)
    }
}
