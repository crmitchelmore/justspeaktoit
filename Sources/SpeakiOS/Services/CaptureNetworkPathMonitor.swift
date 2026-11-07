#if os(iOS)
import Foundation
import Network

@MainActor
final class CaptureNetworkSnapshotState {
    private(set) var snapshot: CaptureConnectivitySnapshot = .unknown
    private(set) var generation: UInt = 0

    @discardableResult
    func restart() -> UInt {
        self.generation &+= 1
        self.snapshot = .unknown
        return self.generation
    }

    func cancel() {
        self.generation &+= 1
        self.snapshot = .unknown
    }

    /// - Returns: whether this delivery is the path becoming available.
    @discardableResult
    func receive(_ snapshot: CaptureConnectivitySnapshot, generation: UInt) -> Bool {
        guard generation == self.generation else { return false }
        let becameAvailable = snapshot == .available && self.snapshot != .available
        self.snapshot = snapshot
        return becameAvailable
    }
}

/// One process-lifetime Network framework adapter. Capture reads its latest
/// delivered snapshot synchronously; it never waits for or probes a path.
@MainActor
final class CaptureNetworkPathMonitor {
    typealias SnapshotProvider = @MainActor () -> CaptureConnectivitySnapshot

    static let shared = CaptureNetworkPathMonitor()

    private let state = CaptureNetworkSnapshotState()
    private let callbackQueue = DispatchQueue(label: "com.justspeaktoit.capture-network-path")
    private var monitor: NWPathMonitor?
    /// Called on the main actor each time the path becomes available.
    var onBecameAvailable: (@MainActor () -> Void)?

    private init() {
        self.restart()
    }

    var snapshot: CaptureConnectivitySnapshot { self.state.snapshot }

    static func liveSnapshotProvider() -> SnapshotProvider {
        let monitor = self.shared
        return { monitor.snapshot }
    }

    func restart() {
        self.monitor?.cancel()
        let generation = self.state.restart()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Self.snapshot(for: path.status)
            Task { @MainActor [weak self] in
                guard let self, self.state.receive(snapshot, generation: generation) else { return }
                self.onBecameAvailable?()
            }
        }
        monitor.start(queue: self.callbackQueue)
    }

    func cancel() {
        self.monitor?.cancel()
        self.monitor = nil
        self.state.cancel()
    }

    nonisolated static func snapshot(for status: NWPath.Status) -> CaptureConnectivitySnapshot {
        switch status {
        case .satisfied:
            return .available
        case .unsatisfied:
            return .unavailable
        case .requiresConnection:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
#endif
