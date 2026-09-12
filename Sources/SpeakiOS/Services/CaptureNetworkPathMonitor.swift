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

    func receive(_ snapshot: CaptureConnectivitySnapshot, generation: UInt) {
        guard generation == self.generation else { return }
        self.snapshot = snapshot
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
                self?.state.receive(snapshot, generation: generation)
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
