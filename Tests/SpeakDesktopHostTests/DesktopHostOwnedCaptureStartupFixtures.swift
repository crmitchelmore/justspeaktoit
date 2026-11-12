import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

actor OwnedStartupGate {
    private var opened: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var entries = 0
    private(set) var events: [String] = []
    private var reenter: (@Sendable () -> Void)?
    func onEntry(_ action: @escaping @Sendable () -> Void) { reenter = action }
    func record(_ value: String) {
        events.append(value)
        let action = reenter
        reenter = nil
        action?()
    }
    init(open: Bool = false) { opened = open }
    func pass() async {
        entries += 1
        observers.forEach { $0.resume() }; observers.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async {
        if entries == 0 { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
actor OwnedStartupWorker: DesktopPressCaptureWorker {
    let opening: OwnedStartupGate
    let closing: OwnedStartupGate
    var failOpen = false
    var failClose = false
    private var failure: (@Sendable (String) -> Void)?
    private(set) var opens = 0
    private(set) var closes = 0
    init(opening: OwnedStartupGate = .init(open: true), closing: OwnedStartupGate = .init(open: true)) {
        self.opening = opening; self.closing = closing
    }
    func configure(open: Bool = false, close: Bool = false) { failOpen = open; failClose = close }
    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        opens += 1
        failure = onFailure
        await opening.pass()
        if failOpen { throw DesktopHostError(message: "synthetic open") }
    }
    func close(id: UUID) async throws {
        closes += 1
        await closing.pass()
        if failClose { throw DesktopHostError(message: "synthetic close") }
    }
    func emitFailure() { failure?("synthetic capture") }
}
