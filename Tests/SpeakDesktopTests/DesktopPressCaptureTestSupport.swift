import Foundation
import SpeakDesktop
import XCTest

actor PressCaptureTestWorker: DesktopPressCaptureWorker {
    enum Failure: Error { case open, close }
    private var holdOpens: Bool
    private var holdCloses: Bool
    private let failOpen: Bool
    private var failedCloses: Int
    private var openGates: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var closeGates: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var openObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closeObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var callbacks: [UUID: @Sendable (Data) -> Void] = [:]
    private var failureCallbacks: [UUID: @Sendable (String) -> Void] = [:]
    private var active: Set<UUID> = []
    private(set) var opens: [UUID] = []
    private(set) var closes: [UUID] = []
    private(set) var maximumActive = 0

    init(holdOpens: Bool = false, holdCloses: Bool = false, failOpen: Bool = false, failedCloses: Int = 0) {
        self.holdOpens = holdOpens
        self.holdCloses = holdCloses
        self.failOpen = failOpen
        self.failedCloses = failedCloses
    }

    func open(
        id: UUID, identity: DesktopPressCaptureIdentity, receive: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        opens.append(id)
        callbacks[id] = receive
        failureCallbacks[id] = onFailure
        active.insert(id)
        maximumActive = max(maximumActive, active.count)
        openObservers.removeAll { count, done in
            guard opens.count >= count else { return false }
            done.resume()
            return true
        }
        if holdOpens { await withCheckedContinuation { openGates[id] = $0 } }
        if failOpen { throw Failure.open }
    }

    func close(id: UUID) async throws {
        closes.append(id)
        closeObservers.removeAll { count, done in
            guard closes.count >= count else { return false }
            done.resume()
            return true
        }
        if holdCloses { await withCheckedContinuation { closeGates[id] = $0 } }
        // Simulate Linux's final flush, which must not pass the closed relay.
        callbacks[id]?(Data([255, 255]))
        if failedCloses > 0 { failedCloses -= 1; throw Failure.close }
        active.remove(id)
    }

    func releaseOpens() {
        holdOpens = false
        let gates = openGates.values
        openGates.removeAll()
        for gate in gates { gate.resume() }
    }

    func releaseCloses() {
        holdCloses = false
        let gates = closeGates.values
        closeGates.removeAll()
        for gate in gates { gate.resume() }
    }

    func waitForOpens(_ count: Int = 1) async {
        if opens.count < count { await withCheckedContinuation { openObservers.append((count, $0)) } }
    }

    func waitForCloses(_ count: Int = 1) async {
        if closes.count < count { await withCheckedContinuation { closeObservers.append((count, $0)) } }
    }

    func emit(_ data: Data, id: UUID? = nil) {
        guard let id = id ?? opens.last, let callback = callbacks[id] else {
            return XCTFail("No capture callback")
        }
        callback(data)
    }

    func fail(id: UUID, message: String) { failureCallbacks[id]?(message) }
}

actor PressCaptureTestProducer {
    private let data: Data
    private let receive: @Sendable (Data) -> Void
    private var gate: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?

    init(data: Data, receive: @escaping @Sendable (Data) -> Void) {
        self.data = data
        self.receive = receive
    }

    func send() async {
        await withCheckedContinuation {
            gate = $0
            pending?.resume()
            pending = nil
        }
        receive(data)
    }

    func waitUntilPending() async {
        if gate == nil { await withCheckedContinuation { pending = $0 } }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

final class PressCaptureTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPCM = Data()
    private var storedFailures: [DesktopPressCaptureError] = []
    private var storedEvents: [DesktopPressCaptureFailureEvent] = []
    private var storedDeliveries: [DesktopPressCapturePCMDelivery] = []
    private var storedBatches: [Data] = []
    private var storedAccepted: [Int] = []
    private var storedFinished = false
    var pcm: Data { lock.withLock { storedPCM } }
    var failures: [DesktopPressCaptureError] { lock.withLock { storedFailures } }
    var events: [DesktopPressCaptureFailureEvent] { lock.withLock { storedEvents } }
    var deliveries: [DesktopPressCapturePCMDelivery] { lock.withLock { storedDeliveries } }
    var batches: [Data] { lock.withLock { storedBatches } }
    var accepted: [Int] { lock.withLock { storedAccepted } }
    var finished: Bool { lock.withLock { storedFinished } }
    func append(_ data: Data) { lock.withLock { storedPCM.append(data) } }
    func fail(_ error: DesktopPressCaptureError) { lock.withLock { storedFailures.append(error) } }
    func observe(_ event: DesktopPressCaptureFailureEvent) { lock.withLock { storedEvents.append(event) } }
    func observe(_ delivery: DesktopPressCapturePCMDelivery) { lock.withLock { storedDeliveries.append(delivery) } }
    func batch(_ data: Data) { lock.withLock { storedBatches.append(data) } }
    func accept(_ value: Int) { lock.withLock { storedAccepted.append(value) } }
    func finish() { lock.withLock { storedFinished = true } }
}

func pressCaptureIdentity(
    device: String = "device", route: String = "route", profile: String = "profile",
    rate: Int = 16_000, frame: Int = 100
) -> DesktopPressCaptureIdentity {
    DesktopPressCaptureIdentity(
        deviceID: device, routeID: route, profileID: profile, sampleRate: rate, frameMilliseconds: frame
    )
}

func pressCaptureAdmission(
    enabled: Bool = true, capability: DesktopPressCaptureCapability = .qualified,
    permission: DesktopPressCapturePermission = .granted, owner: DesktopPressCaptureOwner = .idle
) -> DesktopPressCaptureAdmission {
    DesktopPressCaptureAdmission(enabled: enabled, capability: capability, permission: permission, owner: owner)
}

func pressCaptureLimits() throws -> DesktopPressCaptureBufferLimits {
    try DesktopPressCaptureBufferLimits(preRollFrames: 4, reservedFrames: 16)
}

func assertPressPhase(
    _ lease: DesktopPressCaptureLease, _ expected: DesktopPressCapturePhase,
    file: StaticString = #filePath, line: UInt = #line
) async {
    let actual = await lease.phase
    XCTAssertEqual(actual, expected, file: file, line: line)
}

func assertPressError(
    _ expected: DesktopPressCaptureError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void
) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) } catch {
        XCTAssertEqual(error as? DesktopPressCaptureError, expected, file: file, line: line)
    }
}
