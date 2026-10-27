#if os(iOS)
import Foundation
import Combine
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

/// Owns only a synthetic fixture's directory and defaults. An unsettled worker
/// retains its files for diagnosis instead of racing deletion against admitted IO.
@MainActor
final class HistoryFixtureCleanup {
    private let directory: URL
    private let defaults: UserDefaults
    private let suite: String
    private let history: iOSHistoryManager

    init(directory: URL, defaults: UserDefaults, suite: String, history: iOSHistoryManager) {
        self.directory = directory
        self.defaults = defaults
        self.suite = suite
        self.history = history
    }

    func register(
        on test: XCTestCase, terminal: AnyPublisher<Bool, Never>,
        cancelOwned: @escaping @MainActor () -> Void
    ) {
        test.addTeardownBlock { @MainActor [self] in
            await finish(terminal: terminal, cancelOwned: cancelOwned)
        }
    }

    private func finish(terminal: AnyPublisher<Bool, Never>, cancelOwned: @MainActor () -> Void) async {
        cancelOwned()
        let settled = XCTestExpectation(description: "Owned fixture terminal cleanup")
        let observation = terminal.first(where: { $0 }).sink { _ in settled.fulfill() }
        defer { observation.cancel() }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
            retainUnsettled("terminal receipt did not settle")
            return
        }
        // A ticket behind admitted writes establishes worker quiescence even
        // when cleanup began before a processor or capture was ever admitted.
        let drained = XCTestExpectation(description: "Owned History worker quiesced")
        let barrier = Task { @MainActor [history] in
            await history.loadIfNeededAndWait()
            drained.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [drained], timeout: 2) == .completed else {
            barrier.cancel()
            retainUnsettled("History worker did not quiesce")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        do { try FileManager.default.removeItem(at: directory) } catch {
            XCTFail("Owned fixture cleanup could not remove \(directory.path): \(error)")
        }
    }

    private func retainUnsettled(_ reason: String) {
        let evidence = ["reason": reason, "retainedDirectory": directory.path]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("unsettled-fixture.json"), options: .atomic)
        }
        XCTFail("\(reason); retained owned fixture at \(directory.path)")
    }
}
#endif
