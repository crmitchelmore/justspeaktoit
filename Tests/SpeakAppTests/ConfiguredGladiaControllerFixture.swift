import Foundation
import XCTest
@testable import SpeakApp
@testable import SpeakCore

/// Actual configured Core client and shared Mac controller. Synthetic HTTP,
/// socket and clock seams bypass credentials/capture; production routing is
/// deliberately not exercised by these finalization tests.
@MainActor
final class ConfiguredGladiaControllerFixture {
    static let stopJSON = #"{"type":"stop_recording"}"#
    struct Stop {
        let task: Task<Void, Never>
        let done: XCTestExpectation
        let settlement: ConfiguredGladiaSettlement
    }
    struct Finish {
        let task: Task<String?, Never>
        let done: XCTestExpectation
        let settlement: ConfiguredGladiaSettlement
    }
    struct Background { let done: XCTestExpectation }
    struct Timeout: Error {}

    let transport = AssemblyAIControllerTransport()
    let clock = ConfiguredGladiaControllerClock()
    let sessions: ConfiguredGladiaSessions
    let updates = GladiaControllerBoundaryUpdates()
    let callbackTail = ConfiguredGladiaCallbackTail()
    let delegate = GladiaControllerBoundaryDelegate()
    let client: GladiaLiveClient
    let controller: SharedClientLiveController
    let grace: TimeInterval
    let window: TimeInterval
    private let defaults: UserDefaults
    private let suite = "gladia-configured-controller.\(UUID().uuidString)"
    var socket: AssemblyAIControllerSocket? { transport.sockets.last }

    init(grace: TimeInterval = 0.25, window: TimeInterval? = 0.5, heldSession: Bool = false) throws {
        self.grace = grace
        self.window = window ?? GladiaLive.finalEventWindow
        sessions = ConfiguredGladiaSessions(held: heldSession)
        let sessions = sessions, transport = transport, clock = clock
        client = GladiaLiveClient(
            apiKey: "synthetic-unused-key",
            options: LiveClientOptions(
                keywords: [], assemblyAIKeyterms: [], modulate: .none,
                postStopFinalizeBudget: window, stopGracePeriod: grace
            ), initiateSession: { sessions.initiate($0, completion: $1) },
            makeConnection: { transport.make($0) }, schedule: { clock.schedule($0, action: $1) }
        )
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionsManager(statusProvider: { _ in .granted }, grantHistory: defaults)
        controller = SharedClientLiveController(
            permissionsManager: permissions, audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.gladia-configured.\(UUID().uuidString)"
            ), appSettings: settings
        )
        let client = client, updates = updates, tail = callbackTail
        controller.configure(language: "en_GB", model: "gladia/solaria-1-streaming")
        controller.clientFactory = { client }
        controller.startCaptureAudio = {}
        controller.enqueueClientUpdate = { update in updates.enqueue(update); tail.fire() }
        controller.delegate = delegate
    }

    func start(open: Bool = true) async throws {
        try await controller.start()
        if open { try XCTUnwrap(socket).openAndBegin() }
    }

    func admitPCM(_ data: Data = Data(repeating: 1, count: 3_200), complete: Bool = true) throws {
        client.sendAudio(data)
        if complete { try XCTUnwrap(socket).completeSend() }
    }

    func ownStop(in test: XCTestCase) -> Stop {
        let done = XCTestExpectation(description: "configured controller stop returned")
        let exited = XCTestExpectation(description: "owned controller stop exited")
        let settlement = ConfiguredGladiaSettlement()
        let task = Task { @MainActor [controller] in
            defer { exited.fulfill() }
            await controller.stop()
            settlement.mark(); done.fulfill()
        }
        test.addTeardownBlock { @MainActor [self] in
            task.cancel(); releaseAndCancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return Stop(task: task, done: done, settlement: settlement)
    }

    func ownFinish(in test: XCTestCase) -> Finish {
        let done = XCTestExpectation(description: "configured Core finish returned")
        let exited = XCTestExpectation(description: "owned Core finish exited")
        let settlement = ConfiguredGladiaSettlement(), client = client
        // A deliberately held scheduler effect must never block MainActor.
        let task = Task.detached {
            defer { exited.fulfill() }
            let result = await client.finishAndWait()
            settlement.mark(); done.fulfill()
            return result
        }
        test.addTeardownBlock { @MainActor [self] in
            task.cancel(); releaseAndCancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return Finish(task: task, done: done, settlement: settlement)
    }

    func background(in test: XCTestCase, body: @escaping @Sendable () -> Void) -> Background {
        let done = XCTestExpectation(description: "owned transport callback returned")
        let exited = XCTestExpectation(description: "owned transport callback exited")
        DispatchQueue.global().async {
            defer { exited.fulfill() }
            body(); done.fulfill()
        }
        test.addTeardownBlock { @MainActor [self] in
            releaseAndCancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
        }
        return Background(done: done)
    }

    func beginStop(in test: XCTestCase) async throws -> Stop {
        let stopping = ownStop(in: test)
        try await until("controller's Core finish admission") { client.finishWaiterCount == 1 }
        try await advanceGraceToControl()
        return stopping
    }

    func advanceGraceToControl() async throws {
        let socket = try XCTUnwrap(socket)
        if grace > 0 {
            try await until("captured grace timer") { clock.count(grace) == 1 }
            XCTAssertTrue(socket.controls.isEmpty, "Control waits for the captured grace")
            XCTAssertEqual(clock.fire(grace), 1)
        }
        try await until("actual stop_recording handoff") { socket.controls == [Self.stopJSON] }
    }

    func finish(_ stopping: Stop, completeControl: Bool = true) async throws {
        let socket = try XCTUnwrap(socket)
        if completeControl { try socket.completeSend() }
        socket.emit(#"{"type":"end_session"}"#)
        try await wait(stopping.done)
        await stopping.task.value
    }

    func wait(_ signal: XCTestExpectation, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            releaseAndCancel()
            XCTFail("Owned configured Gladia stage did not settle", file: file, line: line)
            throw Timeout()
        }
    }

    func until(
        _ stage: String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard condition() else {
            releaseAndCancel()
            XCTFail("Missing configured Gladia stage: \(stage)", file: file, line: line)
            throw Timeout()
        }
    }

    func cleanup() {
        releaseAndCancel()
        client.onUtteranceBoundary = nil
        callbackTail.clear()
        delegate.onUpdate = nil; delegate.onPartial = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private func releaseAndCancel() {
        client.cancel()
        clock.releaseHolds()
        updatesRelease?()
    }

    /// Only owned background enqueue holds register a release here.
    var updatesRelease: (() -> Void)?
}

final class ConfiguredGladiaSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var settled: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

final class ConfiguredGladiaCallbackTail: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    func arm(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
    func clear() { lock.withLock { action = nil } }
    func fire() {
        let pending = lock.withLock { let pending = action; action = nil; return pending }
        pending?()
    }
}

final class ConfiguredGladiaControllerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(TimeInterval, @Sendable () -> Void)] = []
    private struct Hold {
        let seconds: TimeInterval
        let entered: XCTestExpectation
        let gate: DispatchSemaphore
    }
    private var held: Hold?
    private var gates: [DispatchSemaphore] = []

    func holdNext(_ seconds: TimeInterval, entered: XCTestExpectation) {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { held = Hold(seconds: seconds, entered: entered, gate: gate); gates.append(gate) }
    }

    func schedule(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        let hold: Hold? = lock.withLock {
            entries.append((seconds, action))
            guard let hold = held, hold.seconds == seconds else { return nil }
            held = nil
            return hold
        }
        if let hold {
            hold.entered.fulfill()
            XCTAssertEqual(hold.gate.wait(timeout: .now() + 2), .success, "Owned scheduler hold is bounded")
        }
    }

    func releaseHolds() { lock.withLock { gates }.forEach { $0.signal() } }
    func count(_ seconds: TimeInterval) -> Int { lock.withLock { entries.filter { $0.0 == seconds }.count } }
    func fire(_ seconds: TimeInterval) -> Int {
        let actions = lock.withLock {
            let selected = entries.filter { $0.0 == seconds }.map(\.1)
            entries.removeAll { $0.0 == seconds }
            return selected
        }
        actions.forEach { $0() }
        return actions.count
    }
    func takeActions() -> [@Sendable () -> Void] {
        lock.withLock { let actions = entries.map(\.1); entries.removeAll(); return actions }
    }
}

final class ConfiguredGladiaSessions: @unchecked Sendable {
    typealias Reply = @Sendable (Result<(statusCode: Int, body: Data), Error>) -> Void
    private let lock = NSLock()
    private let held: Bool
    private var replies: [Reply] = []
    init(held: Bool) { self.held = held }
    var pending: Int { lock.withLock { replies.count } }

    func initiate(_ request: URLRequest, completion: @escaping Reply) -> any GladiaLiveSessionRequest {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "api.gladia.io")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-gladia-key"), "synthetic-unused-key")
        if held { lock.withLock { replies.append(completion) } } else { grant(completion) }
        return ConfiguredGladiaRequest()
    }

    func grantNext() throws {
        let reply = lock.withLock { replies.isEmpty ? nil : replies.removeFirst() }
        grant(try XCTUnwrap(reply))
    }
    private func grant(_ reply: Reply) {
        reply(.success((201, Data(#"{"url":"wss://api.gladia.io/v2/live?token=synthetic-unused-token"}"#.utf8))))
    }
}
private final class ConfiguredGladiaRequest: GladiaLiveSessionRequest { func cancel() {} }
