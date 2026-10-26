#if os(iOS)
import Foundation
import XCTest
@testable import SpeakiOSLib

/// A signalled, time-bounded worker hold, never a MainActor semaphore. All fixture
/// controls and observations share the condition lock with the StorageIO closures.
final class HistoryAsyncStorage: @unchecked Sendable {
    private let condition = NSCondition()
    private let primary: URL
    private var readEntered: XCTestExpectation?
    private var writeEntered: XCTestExpectation?
    private var released = false
    private var writesFail = false
    private var removalFails = false
    private var primaryWritesFail = false
    private var mainThreadObserved = false
    private var holdTimedOut = false

    init(primary: URL) { self.primary = primary }

    var storageIO: IOSHistoryPersistence.StorageIO {
        .init(
            read: { [self] url in
                observe(url: url, isWrite: false)
                return try Data(contentsOf: url)
            },
            write: { [self] data, url in
                observe(url: url, isWrite: true)
                if failWrites || (url == primary && failPrimaryWrites) { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            },
            remove: { [self] url in
                condition.lock()
                mainThreadObserved = mainThreadObserved || Thread.isMainThread
                let fails = removalFails
                condition.unlock()
                if fails { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    var failWrites: Bool {
        get { condition.lock(); defer { condition.unlock() }; return writesFail }
        set { condition.lock(); writesFail = newValue; condition.unlock() }
    }

    var failPrimaryWrites: Bool {
        get { condition.lock(); defer { condition.unlock() }; return primaryWritesFail }
        set { condition.lock(); primaryWritesFail = newValue; condition.unlock() }
    }

    var failRemoval: Bool {
        get { condition.lock(); defer { condition.unlock() }; return removalFails }
        set { condition.lock(); removalFails = newValue; condition.unlock() }
    }

    var observedMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return mainThreadObserved
    }

    var timedOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holdTimedOut
    }

    func holdRead(_ expectation: XCTestExpectation) {
        condition.lock()
        readEntered = expectation
        released = false
        condition.unlock()
    }

    func holdWrite(_ expectation: XCTestExpectation) {
        condition.lock()
        writeEntered = expectation
        released = false
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private func observe(url: URL, isWrite: Bool) {
        condition.lock()
        defer { condition.unlock() }
        mainThreadObserved = mainThreadObserved || Thread.isMainThread
        guard url == primary else { return }
        let entered = isWrite ? writeEntered : readEntered
        guard let entered else { return }
        if isWrite { writeEntered = nil } else { readEntered = nil }
        entered.fulfill()
        let deadline = Date().addingTimeInterval(3)
        while !released {
            if !condition.wait(until: deadline) { holdTimedOut = true; break }
        }
    }
}
#endif
