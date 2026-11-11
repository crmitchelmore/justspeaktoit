import Foundation
import XCTest
@testable import SpeakCore

private final class RegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class RegistryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

final class SystemResourceRegistryTests: XCTestCase {
    func testAcquire_listsHoldOldestFirstAndEndRemovesIt() {
        let clock = RegistryClock()
        let registry = SystemResourceRegistry(now: { clock.now })
        let mic = registry.acquire(kind: .microphone, title: "Dictation", reason: "Recording", owner: "test")
        clock.advance(1)
        let socket = registry.acquire(kind: .providerConnection, title: "Deepgram", reason: "Live", owner: "test")

        XCTAssertEqual(registry.holds.map(\.title), ["Dictation", "Deepgram"])
        XCTAssertEqual(registry.holds(of: .microphone).first?.since, Date(timeIntervalSince1970: 1_000))

        mic.end()
        mic.end()
        XCTAssertEqual(registry.holds.map(\.title), ["Deepgram"])
        withExtendedLifetime(socket) {}
    }

    func testTokenDeinit_endsTheHold() {
        let registry = SystemResourceRegistry()
        var token: SystemResourceToken? = registry.acquire(
            kind: .microphone, title: "Primer", reason: "Warm-up", owner: "test"
        )
        XCTAssertEqual(registry.holds.count, 1)
        withExtendedLifetime(token) {}
        token = nil
        XCTAssertTrue(registry.holds.isEmpty)
    }

    func testHoldWithoutReleaseAction_isNotReleasable() async {
        let registry = SystemResourceRegistry()
        let token = registry.acquire(kind: .localModel, title: "Model", reason: "Loaded", owner: "test")
        XCTAssertFalse(registry.holds[0].isReleasable)
        let released = await registry.release(token.id)
        XCTAssertFalse(released)
        XCTAssertEqual(registry.holds.count, 1)
    }

    func testRelease_runsOwnerActionWhichEndsTheHold() async {
        let registry = SystemResourceRegistry()
        let box = RegistryTokenBox()
        box.token = registry.acquire(
            kind: .microphone, title: "Readiness", reason: "Keyboard", owner: "test",
            releaseTitle: "Stop", release: { box.token?.end() }
        )
        XCTAssertEqual(registry.holds.first?.releaseTitle, "Stop")
        let released = await registry.release(box.token!.id)
        XCTAssertTrue(released)
        XCTAssertTrue(registry.holds.isEmpty)
    }

    func testRelease_thatDoesNotEndTheHold_keepsItVisibleAndRetryable() async {
        let registry = SystemResourceRegistry()
        let calls = RegistryCallCounter()
        let token = registry.acquire(
            kind: .microphone, title: "Stuck", reason: "Bug", owner: "test", release: { calls.increment() }
        )
        await registry.release(token.id)
        XCTAssertEqual(registry.holds.count, 1)
        XCTAssertFalse(registry.holds[0].isReleasing)
        await registry.release(token.id)
        XCTAssertEqual(calls.count, 2)
    }

    func testReleaseAll_releasesOnlyReleasableHoldsOfRequestedKinds() async {
        let registry = SystemResourceRegistry()
        let mic = RegistryTokenBox()
        let socket = RegistryTokenBox()
        mic.token = registry.acquire(
            kind: .microphone, title: "Mic", reason: "", owner: "t", release: { mic.token?.end() }
        )
        socket.token = registry.acquire(
            kind: .providerConnection, title: "Socket", reason: "", owner: "t", release: { socket.token?.end() }
        )
        let model = registry.acquire(kind: .localModel, title: "Model", reason: "", owner: "t")

        let onlyMic = await registry.releaseAll(kinds: [.microphone])
        XCTAssertEqual(onlyMic, 1)
        XCTAssertEqual(registry.holds.map(\.title), ["Socket", "Model"])

        let rest = await registry.releaseAll()
        XCTAssertEqual(rest, 1)
        XCTAssertEqual(registry.holds.map(\.title), ["Model"])
        withExtendedLifetime(model) {}
    }

    func testObserve_deliversCurrentStateAndChangesUntilCancelled() {
        let registry = SystemResourceRegistry()
        let seen = RegistrySnapshotLog()
        let observation = registry.observe { seen.append($0.map(\.title)) }
        let token = registry.acquire(kind: .hotKey, title: "Hotkey", reason: "", owner: "t")
        token.update(detail: "Right ⌥")
        token.update(detail: "Right ⌥")
        observation.cancel()
        token.end()

        XCTAssertEqual(seen.values, [[], ["Hotkey"], ["Hotkey"]])
        XCTAssertEqual(registry.holds.count, 0)
    }
}

private final class RegistryTokenBox: @unchecked Sendable {
    var token: SystemResourceToken?
}

private final class RegistrySnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    var values: [[String]] { lock.withLock { log } }
    func append(_ value: [String]) { lock.withLock { log.append(value) } }
}

final class MicrophoneUseAuditorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    private func hold(_ kind: SystemResourceKind = .microphone) -> SystemResourceHold {
        SystemResourceHold(
            id: UUID(), kind: kind, title: "Dictation", reason: "", owner: "t", since: start, detail: nil,
            releaseTitle: nil, isReleasing: false
        )
    }

    func testOpenMicrophoneWithAHold_isAttributed() {
        var auditor = MicrophoneUseAuditor()
        let held = hold()
        let sample = auditor.observe(osReportsInput: true, holds: [held], at: start)
        XCTAssertEqual(sample.attribution, .attributed([held]))
    }

    func testUnknownOSState_isUnknown() {
        var auditor = MicrophoneUseAuditor()
        XCTAssertEqual(auditor.observe(osReportsInput: nil, holds: [], at: start).attribution, .unknown)
    }

    func testOpenMicrophoneWithoutAHold_isUnattributedAfterGraceAndReportedOnce() {
        var auditor = MicrophoneUseAuditor(grace: 3)
        let unrelated = hold(.providerConnection)
        XCTAssertEqual(auditor.observe(osReportsInput: true, holds: [unrelated], at: start).attribution, .idle)
        XCTAssertEqual(auditor.observe(osReportsInput: true, holds: [], at: start + 2).attribution, .idle)

        let first = auditor.observe(osReportsInput: true, holds: [], at: start + 3)
        XCTAssertEqual(first.attribution, .unattributed(since: start))
        XCTAssertTrue(first.shouldReport)
        let later = auditor.observe(osReportsInput: true, holds: [], at: start + 60)
        XCTAssertEqual(later.attribution, .unattributed(since: start))
        XCTAssertFalse(later.shouldReport)

        _ = auditor.observe(osReportsInput: false, holds: [], at: start + 61)
        _ = auditor.observe(osReportsInput: true, holds: [], at: start + 62)
        XCTAssertTrue(auditor.observe(osReportsInput: true, holds: [], at: start + 65).shouldReport)
    }

    func testHoldWithClosedMicrophone_isFlaggedAfterGrace() {
        var auditor = MicrophoneUseAuditor(grace: 3)
        let held = hold()
        XCTAssertEqual(auditor.observe(osReportsInput: false, holds: [held], at: start).attribution, .attributed([held]))
        XCTAssertEqual(
            auditor.observe(osReportsInput: false, holds: [held], at: start + 3).attribution,
            .claimedButClosed([held])
        )
    }

    func testSwitchingMismatchKind_restartsGrace() {
        var auditor = MicrophoneUseAuditor(grace: 3)
        let held = hold()
        _ = auditor.observe(osReportsInput: false, holds: [held], at: start)
        let sample = auditor.observe(osReportsInput: true, holds: [], at: start + 5)
        XCTAssertEqual(sample.attribution, .idle)
    }

    func testSummary_namesMicrophoneHoldFirst() {
        let mic = hold()
        let model = hold(.localModel)
        XCTAssertEqual(SystemResourceSummary.headline(for: [model, mic]), "Microphone in use: Dictation")
        XCTAssertEqual(SystemResourceSummary.headline(for: [model]), "Holding 1 resource")
        XCTAssertEqual(SystemResourceSummary.headline(for: []), "Not holding any system resources")
        XCTAssertEqual(SystemResourceSummary.duration(since: start, now: start + 7_500), "for 2 h 5 min")
        XCTAssertEqual(SystemResourceSummary.duration(since: start, now: start + 42), "for 42 s")
    }
}
